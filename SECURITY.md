# Security

Lean Term is pre-release software. Security fixes target the current `main` branch;
there is not yet a supported binary release series.

Report a vulnerability privately through GitHub's **Security → Report a vulnerability**
on [mattivilola/lean-term](https://github.com/mattivilola/lean-term/security/advisories/new).
Include the affected revision, reproduction steps and impact. Please omit real
credentials and private terminal history from reports and attachments.

The app runs the user's local shell with that user's permissions. It does not
collect terminal contents or provide a network service. Shell commands, shell
startup files and deliberately detached jobs remain under the user's control.
