# Huntex Backhaul Panel

Huntex Backhaul Panel is a minimal, terminal-based (TUI) management panel designed to simplify working with the **Backhaul reverse tunnel core**.

This project provides a clean, fast, and operator-friendly interface for managing multiple Backhaul instances directly from the terminal, without needing any external panels or dashboards.

The panel focuses on:

- Installing and updating the official Backhaul core from GitHub releases  
- Creating and managing client / server configuration files (TOML)  
- Controlling multiple Backhaul instances via systemd  
- Enabling, disabling, restarting, and monitoring tunnels  
- Viewing service status and logs directly from the terminal  

It is built to be lightweight, dependency-minimal, and compatible with most Linux servers and terminal environments.

---

## Acknowledgements

Special thanks to the **Backhaul project developers**  
for creating an efficient, powerful, and reliable reverse tunnel core that made this panel possible.

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/DavoodHuntex/huntex-backhaul/main/huntex-backhaul.sh | bash

---

## Run

Run the panel using one of the following commands:

👉 **hx-bh**  
👉 **huntex-backhaul**

---

## Notes

- **This panel is intended to be run as root**
- Uses systemd template units: **backhaul@.service**
- Configuration files are stored in: **/root/backhaul**
- The Backhaul core binary is installed in: **/root/backhaul/backhaul**

---

## License

**This project is provided as-is for educational and operational use.**  
Please respect the original Backhaul project license when using the core.
