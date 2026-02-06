# Huntex Backhaul Panel

Huntex Backhaul Panel is a minimal, terminal-based (TUI) management panel designed to simplify working with the **Backhaul reverse tunnel core**.

This project provides a clean, fast, and operator-friendly interface for managing Backhaul services directly from the terminal, without needing to manually handle systemd or configuration files.

## Features

- Install and update the official Backhaul core from GitHub
- Create and manage client/server configuration files
- Manage multiple Backhaul instances using systemd template units
- Start, stop, restart, and monitor tunnels
- View service status and logs directly from the terminal
- Lightweight, dependency-minimal, and server-friendly

## Install

Run the following command as **root**:

```bash
curl -fsSL https://raw.githubusercontent.com/DavoodHuntex/huntex-backhaul/main/huntex-backhaul.sh | bash 
```
---

## Run

Start the panel using one of the following commands:

``` hx-bh  ```
# or
``` huntex-backhaul ```

## Notes

- **This panel is intended to be run as root**
- Uses systemd template units: **backhaul@.service**
- Configuration files are stored in: **/root/backhaul**
- The Backhaul core binary is installed in: **/root/backhaul/backhaul**

## Acknowledgements

Special thanks to the **Backhaul project developers**  
for creating an efficient, powerful, and reliable reverse tunnel core that made this panel possible.

## License

**This project is provided as-is for educational and operational use.**  
Please respect the original Backhaul project license when using the core binary.
