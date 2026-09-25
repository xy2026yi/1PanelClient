#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""1Panel API 测试：验证码登录并获取 swagger JSON（合并自 login_with_captcha.py）。

流程：
1. 面板配置全部从脚本同目录的 .panel_env 读取（参考 .panel_env.example），已设置的环境变量优先；
2. 使用面板 RSA 公钥对密码做混合加密（RSA PKCS#1 v1.5 + AES-256-CBC）；
3. 查询登录设置：仅当面板要求验证码（同 IP 近期输错过密码）时，才取图弹出预览等待输入；
4. 登录后自动把 pcsrftoken 同步到 X-CSRF-Token 请求头（双提交校验）；
5. 获取 swagger doc.json 并写入输出目录（默认当前工作目录下的 logs/）：<面板版本>_doc.json。

运行方式（Pillow 位于 conda-venv 环境）：
    /opt/homebrew/Caskroom/miniconda/base/envs/conda-venv/bin/python get-doc-json.py [输出目录]
输出目录为相对当前工作目录的路径（绝对路径亦可），不传时默认 logs。
"""
import base64
import os
import secrets
import json
import hashlib
import time
from io import BytesIO

import requests
from PIL import Image
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

# ---------------------------------------------------------------------------
# 面板配置：从脚本同目录的 .panel_env 读取（格式见 .panel_env.example），
# 已存在的环境变量优先，可用于临时覆盖
# ---------------------------------------------------------------------------
def _load_panel_env() -> None:
    """读取 .panel_env 中的 KEY=VALUE 行； '#' 开头与空行忽略，不覆盖已有环境变量。"""
    env_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".panel_env")
    if not os.path.exists(env_path):
        return
    with open(env_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


_load_panel_env()

PANEL_URL = os.getenv("PANEL_URL")
PANEL_USER = os.getenv("PANEL_USER")
PANEL_PASSWORD = os.getenv("PANEL_PASSWORD")
# 安全入口码：同时用于 SecurityEntrance Cookie 和 EntranceCode 请求头
PANEL_ENTRANCE_CODE = os.getenv("PANEL_ENTRANCE_CODE")
# 面板 RSA 公钥（Base64 编码的 PEM），登录时作为 Cookie 回传给面板
PANEL_PUBLIC_KEY_B64 = os.getenv("PANEL_PUBLIC_KEY_B64")
# 面板 API 接口密钥（面板设置 - 接口），仅 get_version() 使用，函数内单独校验
PANEL_API_TOKEN = os.getenv("PANEL_API_TOKEN")
# 可选：已登录会话的 hermes 刷新令牌 Cookie，留空则不携带
PANEL_HERMES_SESSION_RT = os.getenv("PANEL_HERMES_SESSION_RT")

# 登录必需项
if not all((PANEL_URL, PANEL_USER, PANEL_PASSWORD, PANEL_ENTRANCE_CODE, PANEL_PUBLIC_KEY_B64)):
    raise SystemExit(
        "缺少面板配置：请将 .panel_env.example 复制为 .panel_env，"
        "并填写 PANEL_URL / PANEL_USER / PANEL_PASSWORD / "
        "PANEL_ENTRANCE_CODE / PANEL_PUBLIC_KEY_B64"
    )

BASE_HEADERS = {
    "Accept": "application/json, text/plain, */*",
    "Accept-Language": "zh",
    "CurrentNode": "local",
    "EntranceCode": PANEL_ENTRANCE_CODE,
    "User-Agent": (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36"
    ),
}


def encrypt_1panel_password(password: str, panel_public_key_b64: str) -> str:
    """生成 1Panel 登录所需的 password 字段，格式：RSA(AES_KEY):IV:AES密文（均为 Base64）。

    1Panel 的约定：随机 16 字节取 hex 得到 32 个 ASCII 字符，直接作为
    AES-256-CBC 的密钥；该密钥再经 RSA PKCS#1 v1.5（非 OAEP）加密。
    """
    public_key = serialization.load_pem_public_key(base64.b64decode(panel_public_key_b64))

    aes_key = secrets.token_hex(16).encode("ascii")
    encrypted_key = public_key.encrypt(aes_key, padding.PKCS1v15())

    iv = secrets.token_bytes(16)
    pad_len = 16 - len(password.encode("utf-8")) % 16
    padded = password.encode("utf-8") + bytes([pad_len]) * pad_len

    encryptor = Cipher(algorithms.AES(aes_key), modes.CBC(iv)).encryptor()
    ciphertext = encryptor.update(padded) + encryptor.finalize()

    return ":".join(
        base64.b64encode(part).decode("ascii")
        for part in (encrypted_key, iv, ciphertext)
    )


def build_session() -> requests.Session:
    """创建带初始 Cookie 的会话；登录返回的 psession/pcsrftoken 由 Session 自动携带。"""
    session = requests.Session()
    session.headers.update(BASE_HEADERS)
    session.cookies.set("panel_public_key", PANEL_PUBLIC_KEY_B64)
    session.cookies.set("SecurityEntrance", PANEL_ENTRANCE_CODE)
    if PANEL_HERMES_SESSION_RT:
        session.cookies.set("hermes_session_rt", PANEL_HERMES_SESSION_RT)
        session.cookies.set("hermes_session_provider", "basic")

    def sync_csrf_header(resp, *args, **kwargs):
        # 1Panel 为双提交校验：请求头 X-CSRF-Token 必须与 Cookie pcsrftoken 值一致；
        # 登录等响应可能轮换该值，故每次响应后同步，保证下一个请求生效
        token = resp.cookies.get("pcsrftoken") or session.cookies.get("pcsrftoken")
        if token:
            session.headers["X-CSRF-Token"] = token

    session.hooks["response"] = [sync_csrf_header]
    return session


def _check(resp: requests.Response, action: str) -> dict:
    """校验 HTTP 状态与业务 code，均成功时返回解析后的 JSON。"""
    resp.raise_for_status()
    body = resp.json()
    if body.get("code") != 200:
        raise RuntimeError(f"{action}失败: {body.get('message') or body}")
    return body


def need_captcha(session: requests.Session) -> bool:
    """查询当前 IP 是否被面板要求验证码（同 IP 近期输错密码后会被要求一段时间）。

    查询失败时按“需要验证码”处理，保持与旧流程一致，避免误判导致登录失败。
    """
    try:
        resp = session.get(f"{PANEL_URL}/api/v2/core/auth/setting", timeout=10)
        data = _check(resp, "获取登录设置")["data"]
    except (requests.RequestException, RuntimeError, KeyError) as e:
        print(f"查询验证码状态失败（{e}），按需要验证码处理")
        return True
    return bool(data.get("needCaptcha"))


def get_captcha(session: requests.Session) -> tuple[str, str]:
    """获取验证码图片，弹出系统预览并等待手动输入。返回 (captchaID, 验证码)。"""
    resp = session.get(f"{PANEL_URL}/api/v2/core/auth/captcha", timeout=10)
    data = _check(resp, "获取验证码")["data"]

    # imagePath 为 Data URI："data:image/png;base64,iVBORw0..."，只取逗号后的 base64 部分
    png_bytes = base64.b64decode(data["imagePath"].partition(",")[2])

    Image.open(BytesIO(png_bytes)).show()  # 系统预览打开，不阻塞脚本
    captcha = input("请输入验证码（算术题请输入计算结果）: ").strip()
    return data["captchaID"], captcha


def login(session: requests.Session, captcha_id: str, captcha: str) -> None:
    """登录面板（携带验证码）；成功后会话 Cookie 中即包含 psession / pcsrftoken。"""
    resp = session.post(
        f"{PANEL_URL}/api/v2/core/auth/login",
        json={
            "name": PANEL_USER,
            "password": encrypt_1panel_password(PANEL_PASSWORD, PANEL_PUBLIC_KEY_B64),
            "captcha": captcha,
            "captchaID": captcha_id,
            "authMethod": "session",
            "authSource": "local",
            "language": "zh",
        },
        timeout=10,
    )
    _check(resp, "登录")


def get_api_json(session: requests.Session) -> dict:
    resp = session.get(f"{PANEL_URL}/1panel/swagger/doc.json", timeout=10)
    # print(resp.json())
    return resp.json()


# 初始化，设置headers
def _init_headers(token):
    # unix 时间戳，1Panel需要秒级
    unix_time = int(time.time())
    # 将时间戳转为str字符串格式
    str_time = str(unix_time)

    # 面板API接口密钥
    api_token = token

    # 1Panel 自定义 Token 格式
    token_data = '1panel' + api_token + str_time

    # 创建MD5对象
    md5 = hashlib.md5()
    # 修改字符串编码格式
    md5.update(token_data.encode('utf-8'))

    # 加密后16进制字符串
    token = md5.hexdigest()

    # 1Panel 自定义 headers
    headers = {
        '1Panel-Token': token,
        '1Panel-Timestamp': str_time,
    }

    return headers


def get_version():
    if not PANEL_API_TOKEN:
        raise SystemExit("缺少 PANEL_API_TOKEN：请在 .panel_env 中配置面板接口密钥（面板设置 - 接口）")
    _headers = _init_headers(PANEL_API_TOKEN)
    _headers['accept-language'] = 'zh'
    resp = requests.post(
        f"{PANEL_URL}/api/v2/core/settings/search/base",
        headers=_headers,
        timeout=10
    )
    return resp.json()['data']['systemVersion']


def write_api_json(new_json_version, new_api_json: dict, output_dir: str = "logs") -> None:
    from pathlib import Path
    base_dir = Path.cwd().resolve()
    # 路径经 resolve 规范化后必须仍位于当前工作目录之内，防止越界写入
    save_dir = (base_dir / output_dir).resolve()
    if not save_dir.is_relative_to(base_dir):
        raise ValueError(f"输出目录必须位于当前工作目录内: {output_dir}")
    save_dir.mkdir(parents=True, exist_ok=True)
    save_path = (save_dir / (new_json_version + '_doc.json')).resolve()
    if not save_path.is_relative_to(base_dir):
        raise ValueError(f"输出路径越界: {new_json_version}")
    with save_path.open('w', encoding='utf-8') as f:
        json.dump(new_api_json, f, ensure_ascii=False, indent=4)
    print(f"doc.json 已写入: {save_path}")


def logout(session: requests.Session) -> None:
    resp = session.post(f"{PANEL_URL}/api/v2/core/auth/logout", timeout=10)
    print(resp.json())


def main(output_dir: str = "logs") -> None:
    session = build_session()
    if need_captcha(session):
        captcha_id, captcha = get_captcha(session)  # 弹出验证码图片并等待输入
    else:
        print("当前 IP 无需验证码，跳过验证码直接登录")
        captcha_id, captcha = "", ""
    login(session, captcha_id, captcha)
    now_panel_version = get_version()
    # print(session.cookies)
    t_api_json = get_api_json(session)
    write_api_json(now_panel_version, t_api_json, output_dir)
    logout(session)


if __name__ == "__main__":
    # 可选位置参数：输出目录（相对当前工作目录），不传默认 logs
    import sys
    main(sys.argv[1] if len(sys.argv) > 1 else "logs")
