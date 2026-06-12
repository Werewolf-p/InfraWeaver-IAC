#!/usr/bin/env python3
"""
send-welcome-email.py — Send a styled onboarding welcome email to a new user.

Sends to the user's own email address (from users.yaml), NOT the admin SMTP_TO.
No vault credentials included — only SSO setup + password reset link.

Usage:
  python3 scripts/send-welcome-email.py \\
    --username <username> \\
    --recovery-link <url>

Environment variables required:
  SMTP_USERNAME, SMTP_PASSWORD
"""
import argparse
import os
import smtplib
import ssl
import sys
from datetime import datetime, timezone
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText

import yaml

# ── Args ──────────────────────────────────────────────────────────────────────
parser = argparse.ArgumentParser()
parser.add_argument("--username", required=True)
parser.add_argument("--recovery-link", required=True, dest="recovery_link")
args = parser.parse_args()

# ── Load users.yaml ───────────────────────────────────────────────────────────
with open("users.yaml") as f:
    config = yaml.safe_load(f)

user_data = (config.get("users") or {}).get(args.username)
if not user_data:
    print(f"❌ User '{args.username}' not found in users.yaml", file=sys.stderr)
    sys.exit(1)

user_email = (user_data.get("email") or "").strip()
if not user_email or "@" not in user_email:
    print(f"⚠️  User '{args.username}' has no valid email in users.yaml — skipping welcome email")
    sys.exit(0)

user_name    = user_data.get("name", args.username)
access_level = user_data.get("access_level", "platform-user")

# ── SMTP ──────────────────────────────────────────────────────────────────────
smtp_host = "smtp-mail.outlook.com"
smtp_port = 587
smtp_user = os.environ["SMTP_USERNAME"]
smtp_pass = os.environ["SMTP_PASSWORD"]

# ── Content ───────────────────────────────────────────────────────────────────
timestamp    = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
base_domain  = os.environ.get("BASE_DOMAIN", "yourdomain.com")
auth_url     = f"https://auth.{base_domain}"
homepage_url = f"https://home.int.{base_domain}"
first_name   = user_name.split()[0]
subject      = f"🎉 Welcome to InfraWeaver — your account is ready, {first_name}"

if access_level == "admin":
    access_desc = "Full admin access — all services including ArgoCD, OpenBao, Grafana, Longhorn"
else:
    access_desc = "Platform user — Homepage dashboard, ArgoCD (read-only)"

# ── Helpers (same InfraWeaver Prime theme as send-deploy-email.py) ────────────
def mono_block(value, color="#00d8ff"):
    return (
        f'<div style="background:#060c18;border:1px solid #1e2d45;border-left:3px solid {color};'
        f'border-radius:6px;padding:10px 14px;font-family:\'Courier New\',Courier,monospace;'
        f'font-size:13px;color:{color};word-break:break-all;letter-spacing:0.5px;">'
        f"{value}</div>"
    )

def label(text):
    return (
        f'<p style="margin:0 0 4px;color:#475569;font-size:10px;'
        f'text-transform:uppercase;letter-spacing:1.5px;">{text}</p>'
    )

def step_header(num, total, icon, title, accent="#00d8ff"):
    return f"""\
      <p style="margin:0 0 8px;color:#00d8ff;font-size:11px;font-family:'Courier New',monospace;
                letter-spacing:2px;">STEP {num} OF {total}</p>
      <table width="100%" cellpadding="0" cellspacing="0"
             style="background:#111827;border:1px solid #1e2d45;border-radius:10px;
                    margin-bottom:20px;overflow:hidden;border-top:2px solid {accent};">
        <tr>
          <td style="background:linear-gradient(90deg,#060c18,#0a0e17);padding:14px 20px;
                     border-bottom:1px solid #1e2d45;">
            <span style="font-size:20px;vertical-align:middle;">{icon}</span>
            <span style="color:#00d8ff;font-size:13px;font-weight:700;margin-left:10px;
                         text-transform:uppercase;letter-spacing:1.5px;vertical-align:middle;">{title}</span>
          </td>
        </tr>"""

# ── HTML ──────────────────────────────────────────────────────────────────────
html = f"""\
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>Welcome to InfraWeaver</title>
</head>
<body style="margin:0;padding:0;background:#0a0e17;font-family:'Segoe UI',Arial,sans-serif;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#0a0e17;padding:32px 16px;">
<tr><td align="center">
<table width="620" cellpadding="0" cellspacing="0" style="max-width:620px;width:100%;">

  <!-- HEADER -->
  <tr>
    <td style="background:linear-gradient(135deg,#0d1420 0%,#060c18 50%,#0a1628 100%);
               border-radius:14px 14px 0 0;padding:36px 40px 28px;text-align:center;
               border-top:3px solid #00d8ff;">
      <div style="font-size:11px;color:#00d8ff;font-family:'Courier New',monospace;
                  letter-spacing:3px;margin-bottom:12px;opacity:0.6;">
        &#9632;&#9632;&#9632; INFRAWEAVER &#9632;&#9632;&#9632;
      </div>
      <h1 style="margin:0 0 4px;font-size:32px;font-weight:900;color:#ffffff;letter-spacing:-1px;">
        <span style="color:#00d8ff;">Infra</span>Weaver
      </h1>
      <p style="margin:0;font-size:11px;color:#475569;text-transform:uppercase;letter-spacing:3px;">
        Infrastructure, Woven Together
      </p>
    </td>
  </tr>

  <!-- STATUS BAR -->
  <tr>
    <td style="background:#0d1420;padding:12px 40px;border-left:1px solid #1e2d45;
               border-right:1px solid #1e2d45;">
      <table width="100%" cellpadding="0" cellspacing="0">
        <tr>
          <td>
            <span style="background:#0a2010;color:#9fef00;font-size:11px;font-weight:700;
                         padding:4px 10px;border-radius:20px;border:1px solid #1a4020;
                         font-family:'Courier New',monospace;letter-spacing:1px;">
              ✓ ACCOUNT PROVISIONED
            </span>
          </td>
          <td align="right" style="color:#475569;font-size:11px;font-family:'Courier New',monospace;">
            {timestamp}
          </td>
        </tr>
      </table>
    </td>
  </tr>

  <!-- BODY -->
  <tr>
    <td style="background:#0a0e17;padding:28px 40px;border-left:1px solid #1e2d45;
               border-right:1px solid #1e2d45;">

      <p style="margin:0 0 20px;color:#e2e8f0;font-size:15px;line-height:1.7;">
        Hi <strong style="color:#00d8ff;">{user_name}</strong>,<br>
        your InfraWeaver homelab account has been provisioned.
        Follow the 3 steps below to get connected.
      </p>

      <!-- ACCESS LEVEL badge -->
      <table width="100%" cellpadding="0" cellspacing="0"
             style="background:#111827;border:1px solid #1e2d45;border-radius:8px;
                    margin-bottom:24px;padding:16px 20px;">
        <tr><td>
          {label("Your Access Level")}
          {mono_block(access_desc, "#9fef00")}
        </td></tr>
      </table>

      <!-- STEP 1: Set password -->
      {step_header(1, 2, "🔑", "Set Your Password", "#00d8ff")}
        <tr>
          <td style="padding:20px;">
            <p style="margin:0 0 14px;color:#94a3b8;font-size:13px;line-height:1.6;">
              Click the link below to set your password.
              The link expires in <strong style="color:#f59e0b;">30 minutes</strong>
              — if it's expired, contact the admin to generate a new one.
            </p>
            {label("Login URL")}
            {mono_block(f'<a href="{auth_url}" style="color:#00d8ff;text-decoration:none;">{auth_url}</a>')}
            <div style="height:12px;"></div>
            {label("Your Username")}
            {mono_block(args.username, "#9fef00")}
            <div style="height:12px;"></div>
            {label("Set Password Link (expires 30 min)")}
            {mono_block(f'<a href="{args.recovery_link}" style="color:#9fef00;text-decoration:none;word-break:break-all;">{args.recovery_link}</a>', "#9fef00")}
          </td>
        </tr>
      </table>

      <!-- STEP 2: Dashboard -->
      {step_header(2, 2, "🏠", "Open Your Dashboard", "#7c3aed")}
        <tr>
          <td style="padding:20px;text-align:center;">
            <p style="margin:0 0 16px;color:#94a3b8;font-size:13px;">
              After connecting to VPN, open the homelab dashboard to access all your services.
            </p>
            <a href="{homepage_url}"
               style="display:inline-block;background:#00d8ff;color:#060c18;font-size:14px;
                      font-weight:900;padding:14px 36px;border-radius:8px;text-decoration:none;
                      letter-spacing:1px;font-family:'Courier New',monospace;">
              OPEN DASHBOARD &rarr;
            </a>
            <p style="margin:12px 0 0;color:#475569;font-size:11px;
                      font-family:'Courier New',monospace;">
              {homepage_url}
            </p>
          </td>
        </tr>
      </table>

    </td>
  </tr>

  <!-- FOOTER -->
  <tr>
    <td style="background:#060c18;padding:20px 40px;border-radius:0 0 14px 14px;
               border:1px solid #1e2d45;border-top:1px solid #1e2d45;text-align:center;">
      <p style="margin:0;color:#1e2d45;font-size:10px;font-family:'Courier New',monospace;
                letter-spacing:1px;">
        INFRAWEAVER PLATFORM &nbsp;·&nbsp; KEEP YOUR CREDENTIALS SECURE
        &nbsp;·&nbsp; CONTACT ADMIN IF YOU NEED HELP
      </p>
    </td>
  </tr>

</table>
</td></tr>
</table>
</body>
</html>
"""

plain = f"""\
Welcome to InfraWeaver, {user_name}!
=====================================
Your account has been provisioned.

Access: {access_desc}

STEP 1 — Set Your Password
  Login URL  : {auth_url}
  Username   : {args.username}
  Set password: {args.recovery_link}
  (Link expires in 30 minutes)

STEP 2 — Open Dashboard (requires VPN)
  URL : {homepage_url}
"""

msg = MIMEMultipart("alternative")
msg["Subject"] = subject
msg["From"]    = smtp_user
msg["To"]      = user_email
msg.attach(MIMEText(plain, "plain"))
msg.attach(MIMEText(html, "html"))

ctx = ssl.create_default_context()
try:
    with smtplib.SMTP(smtp_host, smtp_port) as s:
        s.ehlo()
        s.starttls(context=ctx)
        s.login(smtp_user, smtp_pass)
        s.sendmail(smtp_user, user_email, msg.as_string())
    print(f"✅ Welcome email sent to {user_email} ({user_name})")
except Exception as e:
    print(f"❌ Failed to send welcome email to {user_email}: {e}", file=sys.stderr)
    sys.exit(1)
