"""
Доставка одноразовых кодов: SMS и почта.

Почта — любой SMTP-сервер (Gmail, Yandex, Mail.ru, Mailgun, Postbox, свой Postfix):
    ORBITA_SMTP_HOST, ORBITA_SMTP_PORT (465 = SSL, 587 = STARTTLS), ORBITA_SMTP_USER,
    ORBITA_SMTP_PASS, ORBITA_SMTP_FROM  (например "Orbita <no-reply@your-domain.ru>")

SMS — через провайдера (ORBITA_SMS_PROVIDER):
    smsru   — sms.ru:      ORBITA_SMS_API_ID, ORBITA_SMS_FROM (необязательно, имя отправителя)
    smsc    — smsc.ru:     ORBITA_SMS_LOGIN, ORBITA_SMS_PASSWORD, ORBITA_SMS_FROM
    twilio  — Twilio:      ORBITA_TWILIO_SID, ORBITA_TWILIO_TOKEN, ORBITA_TWILIO_FROM
    webhook — свой шлюз:   ORBITA_SMS_WEBHOOK (POST JSON {"phone","text"})

Ключи провайдеров хранятся только в окружении сервера — в приложение они не попадают.
"""
import json
import os
import smtplib
import ssl
import urllib.error
import urllib.parse
import urllib.request
from email.message import EmailMessage
from email.utils import formatdate, make_msgid

TIMEOUT = 15


class DeliveryError(Exception):
    pass


def env(name, default=""):
    return os.environ.get(name, default).strip()


def email_configured():
    return bool(env("ORBITA_SMTP_HOST") and env("ORBITA_SMTP_FROM"))


def sms_provider():
    p = env("ORBITA_SMS_PROVIDER").lower()
    ready = {
        "smsru": bool(env("ORBITA_SMS_API_ID")),
        "smsc": bool(env("ORBITA_SMS_LOGIN") and env("ORBITA_SMS_PASSWORD")),
        "twilio": bool(env("ORBITA_TWILIO_SID") and env("ORBITA_TWILIO_TOKEN") and env("ORBITA_TWILIO_FROM")),
        "webhook": bool(env("ORBITA_SMS_WEBHOOK")),
    }
    return p if ready.get(p) else ""


def configured(channel):
    return email_configured() if channel == "email" else bool(sms_provider())


# ---------- почта ----------

def send_email(to, code, lang="ru"):
    if not email_configured():
        raise DeliveryError("email_not_configured")
    ru = lang != "en"
    msg = EmailMessage()
    msg["Subject"] = ("Код для входа в Orbita: %s" if ru else "Your Orbita code: %s") % code
    msg["From"] = env("ORBITA_SMTP_FROM")
    msg["To"] = to
    msg["Date"] = formatdate(localtime=True)
    msg["Message-ID"] = make_msgid()
    body = (("Ваш код подтверждения Orbita: %s\n\nОн действует 5 минут. Никому его не сообщайте.\n"
             "Если вы не запрашивали код — просто проигнорируйте письмо.\n") if ru else
            ("Your Orbita confirmation code: %s\n\nIt is valid for 5 minutes. Don't share it with anyone.\n"
             "If you didn't request it, just ignore this email.\n")) % code
    msg.set_content(body)
    host, port = env("ORBITA_SMTP_HOST"), int(env("ORBITA_SMTP_PORT", "587"))
    user, password = env("ORBITA_SMTP_USER"), env("ORBITA_SMTP_PASS")
    ctx = ssl.create_default_context()
    try:
        if port == 465:
            smtp = smtplib.SMTP_SSL(host, port, timeout=TIMEOUT, context=ctx)
        else:
            smtp = smtplib.SMTP(host, port, timeout=TIMEOUT)
            smtp.ehlo()
            if env("ORBITA_SMTP_TLS", "1") != "0":
                smtp.starttls(context=ctx)
                smtp.ehlo()
        with smtp:
            if user:
                smtp.login(user, password)
            smtp.send_message(msg)
    except (OSError, smtplib.SMTPException) as e:
        raise DeliveryError("email_failed: %s" % e.__class__.__name__)


# ---------- SMS ----------

def _post(url, data=None, headers=None, auth=None):
    req = urllib.request.Request(url, data=data, headers=headers or {}, method="POST" if data is not None else "GET")
    if auth:
        import base64
        req.add_header("Authorization", "Basic " + base64.b64encode(("%s:%s" % auth).encode()).decode())
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except OSError as e:
        raise DeliveryError("sms_unreachable: %s" % e.__class__.__name__)


def send_sms(phone, code, lang="ru"):
    provider = sms_provider()
    if not provider:
        raise DeliveryError("sms_not_configured")
    text = (("Ваш код для входа в Orbita: %s. Никому его не сообщайте.") if lang != "en"
            else ("Your Orbita login code: %s. Don't share it with anyone.")) % code
    digits = phone.lstrip("+")

    if provider == "smsru":
        params = {"api_id": env("ORBITA_SMS_API_ID"), "to": digits, "msg": text, "json": 1}
        if env("ORBITA_SMS_FROM"):
            params["from"] = env("ORBITA_SMS_FROM")
        status, body = _post("https://sms.ru/sms/send?" + urllib.parse.urlencode(params))
        try:
            ok = json.loads(body).get("status") == "OK"
        except ValueError:
            ok = False
        if status != 200 or not ok:
            raise DeliveryError("sms_rejected")

    elif provider == "smsc":
        params = {"login": env("ORBITA_SMS_LOGIN"), "psw": env("ORBITA_SMS_PASSWORD"), "phones": digits,
                  "mes": text, "fmt": 3, "charset": "utf-8"}
        if env("ORBITA_SMS_FROM"):
            params["sender"] = env("ORBITA_SMS_FROM")
        status, body = _post("https://smsc.ru/sys/send.php?" + urllib.parse.urlencode(params))
        try:
            ok = "error" not in json.loads(body)
        except ValueError:
            ok = False
        if status != 200 or not ok:
            raise DeliveryError("sms_rejected")

    elif provider == "twilio":
        sid = env("ORBITA_TWILIO_SID")
        form = urllib.parse.urlencode({"To": "+" + digits, "From": env("ORBITA_TWILIO_FROM"), "Body": text}).encode()
        status, _ = _post("https://api.twilio.com/2010-04-01/Accounts/%s/Messages.json" % sid, form,
                          {"Content-Type": "application/x-www-form-urlencoded"}, (sid, env("ORBITA_TWILIO_TOKEN")))
        if status not in (200, 201):
            raise DeliveryError("sms_rejected")

    elif provider == "webhook":
        status, _ = _post(env("ORBITA_SMS_WEBHOOK"), json.dumps({"phone": "+" + digits, "text": text}).encode(),
                          {"Content-Type": "application/json"})
        if not 200 <= status < 300:
            raise DeliveryError("sms_rejected")
