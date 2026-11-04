# Approved branding handoffs

The user explicitly authorized direct coordination. If a destination chat cannot
resume, the following descriptions can be pasted there.

## Lean VS Code app and leanvscode.com

Apply the approved **01 — CRT family** editor branding from:
`/Users/matti/Development/ILOapps/leanterm-macosx/branding/approved/crt-family/lean-vs-code/`.
Verify all files against the parent `manifest.json`. The new editor icon is teal
with mint curly braces; the old emerald prompt icon now belongs to Lean Term.

Update active product branding assets, build an appropriate new Apple Silicon
version, sign/notarize, validate the packaged icon and normal release checks,
publish the release and update feed through the existing workflow. Preserve
unreleased work and the local duplicate-registration workflow fixes; choose a
safe release base/version rather than accidentally shipping unfinished changes.
Keep the bundle identifier/storage/update identity and unnumbered installed app
name. Do not patch the installed signed app's resources or force-close user work.
Report source SHA, version, release URL, signing/notarization and install status.

Update the existing Lean VS Code Site, project
`appgprj_6ab788fc2ad081919bf11b70e6ca5cb1`, to use its new logos and favicons.
Preserve project ID/audience and use the Sites source/publishing workflow.
Add a small Lean-family section promoting **Lean Term** with its emerald icon,
linking `https://leanterm.com`, and honestly label the terminal in development.
Keep existing verified editor benchmark claims intact. Publish and report the
verified Site version/URL.

## Lean Term website

Apply the approved **01 — CRT family** terminal branding from:
`/Users/matti/Development/ILOapps/leanterm-macosx/branding/approved/crt-family/lean-term/`.
Verify the parent manifest. The emerald `>_` icon is now Lean Term's canonical
identity. Replace old provisional product marks with these final assets across
header/footer, favicon/touch/manifest references and existing brand images.

Preserve the existing Site project `appgprj_6aeb4f168730819182d281cfe02f4ef2`,
audience and source workflow. Add a small Lean-family section promoting
**Lean VS Code** with its teal braces icon and `https://leanvscode.com`.
Retain honest in-development/download status and the separate task to publish
actual initial-version performance later. Publish and report the verified Site
version/URL. Parent app repository files belong to the app chat.
