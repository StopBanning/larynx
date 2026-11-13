# Security

Larynx runs entirely on your Mac: it has no server, no account and makes no network connections while dictating
(`tests/privacy.py` checks this). It does hold sensitive things locally: your dictation history, optional
recordings, and the Accessibility and Input Monitoring permissions.

## Reporting a problem

Please report privately: on the repository page, open the **Security** tab and choose **Report a vulnerability**.
If that option is not shown, open an issue that says only "security report, please contact me" with no details,
and you will be contacted.

Useful to include: the Larynx version (About Larynx), your macOS version, and the steps. Please don't include
real dictated text.

Things that count: anything that sends audio, text or screen content off the Mac; anything stored that
[docs/PRIVACY.md](docs/PRIVACY.md) says is never stored (password fields, password managers); a way for another
app or a web page to make Larynx type or reveal something; a problem in the install script.

Only the latest release is supported.
