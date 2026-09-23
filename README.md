# Polynt IT Toolbox

A portable Windows PowerShell 5.1 toolbox for routine computer, Active Directory, and Assyst asset-management work. The interface is implemented with Windows Presentation Foundation (WPF), so no separate UI framework needs to be installed.

## Repository contents

- `Launch-PolyntToolbox.vbs` starts the application without showing a PowerShell console.
- `tools\PolyntToolbox.ps1` contains the WPF interface.
- `tools\functions.ps1` contains the reusable support functions.
- `tools\PsExec.exe` is used only to launch Remote Assistance in the interactive desktop session.
- `tools\README.md` records the PsExec source, version, checksum, and documentation link.

## Requirements

- Windows 10 or Windows 11 with Windows PowerShell 5.1.
- Connectivity to the applicable Active Directory domain and to the Assyst API.
- RSAT Active Directory tools for AD lookups and changes.
- The Microsoft Windows LAPS PowerShell module for LAPS retrieval.
- Remote WMI/DCOM, administrative shares, Remote Desktop, or Remote Assistance enabled as required by the action being used.
- The Windows Secondary Logon service for tools launched under the saved administrator identity.

The toolbox does not use WinRM, PowerShell remoting, `Invoke-Command`, or PowerShell sessions.

## Starting the toolbox

Double-click `Launch-PolyntToolbox.vbs`.

It can also be started directly for troubleshooting:

```powershell
powershell.exe -STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File .\tools\PolyntToolbox.ps1
```

Keep the launcher, `tools` directory, scripts, and `PsExec.exe` together when copying the application to another computer.

## First-time setup

1. Open **Settings**.
2. Choose an administrator-credential domain, enter the support agent's username and password for that domain, then select **Save credential**. Repeat for every domain the agent supports.
3. Enter the Assyst REST base URL and the Base64-encoded `user:password` value, choose whether the test server's self-signed certificate is allowed, select the default movement reason, and select **Save Assyst settings**.
4. Choose light or dark mode as preferred.

The default Assyst test URL is `https://itsupporttest.polynt.net/assystREST/v2`. Leaving the Basic value blank during a later save retains the currently stored value.

## RSAT and LAPS installation

When an Active Directory command is missing, the interface offers to install the RSAT Active Directory capability. Accepting the prompt starts an elevated Windows PowerShell process and runs:

```powershell
Add-WindowsCapability -Online -Name 'Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0'
```

Windows displays a UAC prompt because adding a Windows capability requires local elevation. After installation, the toolbox imports the `ActiveDirectory` module and retries the original action.

The installation source is Windows Update or the organization's configured Windows feature source. Company policy can therefore block or redirect the installation.

The toolbox does not automatically install Windows LAPS. If the `Get-LapsADPassword` command is unavailable, install current Windows updates or the company-approved Windows LAPS component, then reopen the toolbox.

## Credentials and local data

Administrator and Assyst credentials are saved per Windows user under `%LOCALAPPDATA%\PolyntToolbox`:

- `credentials.xml` contains the administrator credentials, stored separately for `polynt.net`, `rsn.chem.corp.local`, and `eu.reichhold.com`.
- `assyst.xml` contains the Assyst settings and Basic value.
- `state.json` contains recent computer/item names and the theme preference.

On Windows, credential values exported to the XML files are protected with DPAPI and can only be decrypted by the same Windows user on the same computer. They are not stored in the application directory. A legacy single `credential.xml` file is treated as the Polynt credential and is carried into the new store the next time credentials are saved. `POLYNT_ADMIN_USER` and `POLYNT_ADMIN_PASSWORD` remain optional deployment-managed fallbacks for Polynt; `ASSYST_API_BASE` and `ASSYST_BASIC_AUTH` can configure Assyst.

Remote Desktop and **Open C drive** prepare the saved administrator credential with Windows Credential Manager (`cmdkey`). Windows may retain those target-specific entries after the application closes. Remote Assistance passes the saved administrator identity to the bundled PsExec launcher.

Read-only AD computer, description, user, and group lookups use the signed-in Windows account. AD changes, LAPS, BitLocker recovery, remote inventory, remote session checks, administrative shares, RDP, Remote Assistance, and administrative launchers use the saved administrator credential for the domain selected on the relevant tab.

## Computers

The **Computers** tab provides:

- Exact computer lookup by name.
- Alphabetical AD description search with selectable results.
- AD computer-description updates.
- Serial number, model, and supported HP dock inventory.
- Ping and DNS details.
- Remote C drive, Remote Desktop, and Remote Assistance launchers.
- Logged-in-user lookup, with a remote/disconnected terminal-session fallback when no interactive console user is reported.
- Installed-software inventory through the remote registry WMI provider. It does not use `Win32_Product`.
- Computer enable/move actions for the configured sites.
- LAPS and BitLocker recovery retrieval and copying.
- Administrator PowerShell, Active Directory Users and Computers, and Computer Management launchers.

Polynt is selected by default. Changing the computer domain changes both the AD server used by domain-aware lookups and the administrator credential used by remote and privileged computer actions. **Enable / move** remains Polynt-only because its destination OUs are specific to the Polynt domain.

The computer and Assyst item fields retain up to 15 recent entries per Windows user.

## Users & Groups

The **Users & Groups** tab supports user lookup, account unlock, and password reset. Password reset can require a password change at the next login.

The group-transfer section compares two users' direct AD group memberships. It can copy one selected membership or every missing direct membership in either direction. Existing memberships are retained, and the primary group is not changed.

Read-only user and group lookups use the signed-in account. Unlock, password reset, and group changes use the saved administrator credential corresponding to the selected user domain.

## Assets (Assyst)

The **Assets (Assyst)** tab supports:

- Exact item lookup by short code.
- Assignment to an owner email address and automatic `Deployed` status.
- Stock placement in Drocourt or Bordeaux, with the corresponding generic owner and `In Stock` status.
- Owner-device lookup in two side-by-side lists and transfer in either direction.
- Optional display of discontinued devices; they are crossed out and sorted last.
- Export of one or more contracts to semicolon-delimited CSV with contract number, owner, serial, and model.

The movement-reason selector at the top applies to assignment, transfer, and stock actions. Its initial value is configured in **Settings**.

Selecting an owner-list device makes it the active item. **Use computer lookup** only copies the current computer name from the **Computers** tab into the Assyst item field; it does not query or modify Assyst by itself.

An assignment creates and verifies the Assyst movement using the target user's user ID, department, cost centre, room, SLA, status, and movement reason. It then updates the visible user association, removes other active user assignments, and verifies that exactly one active assignment remains for the intended owner.

When **Allow self-signed certificate** is enabled, certificate validation is bypassed only during an Assyst API request and restored immediately afterward. This option is intended for the test server.

## Results

The results drawer opens when an action returns output. It can be resized, hidden, and reopened. **Previous** and **Next result** move through records separated by blank lines.

Use **Find** or `Ctrl+F` to search the displayed output. Enter moves to the next match, Shift+Enter moves to the previous match, and Escape closes the search row.

## Troubleshooting

- **Missing AD command:** accept the RSAT installation prompt or install the RSAT Active Directory capability through company software management.
- **Remote inventory access denied:** verify the saved administrator credential and the target's WMI/DCOM firewall and access policy.
- **Open C drive access denied:** verify that the administrative share is enabled and that no existing SMB connection to the same computer is using a different account.
- **Administrative launcher does nothing:** verify the Secondary Logon service and that the relevant MMC/RSAT component is installed.
- **Remote Assistance does not open:** verify that `tools\PsExec.exe` is present and allowed by endpoint security.
- **Assyst request fails:** verify the API URL, Basic value, certificate setting, and the API account's permissions.

Errors are shown in both a dialog and the results drawer.

## Using the functions directly

The backend can be dot-sourced independently:

```powershell
. .\tools\functions.ps1
Get-PC -Name PC123 -Domain polynt
Get-SN -Name PC123
```

`New-Label` remains available in the backend but is not currently exposed in the interface. Set `POLYNT_LABEL_SCRIPT` before using it.

## Repository hygiene

The included `.gitignore` excludes local credential/settings XML files, diagnostic responses, temporary test scripts, screenshots, logs, and CSV exports. Do not commit files copied from `%LOCALAPPDATA%\PolyntToolbox`.
