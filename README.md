# ha-vw-app-adb-charging

Start and stop charging a Volkswagen EV from Home Assistant **without a wallbox and without a working VW API**, by remote-controlling the official VW app on a spare Android phone via ADB.

Built for an ID-family car charging from a household socket (granny charger, ~2.3 kW). The car API we had left only reported data and could no longer start or stop charging, and there is no wallbox to switch. The app still can, so Home Assistant now taps the buttons for us.

> **This is a hack.** It taps on screen elements by their text. It breaks when the app changes, and the texts here are for a **German** app UI. Expect to recalibrate. The original (German) version has been running daily since 31 October 2026: starting and stopping for PV surplus, a minimum battery level and trips.
>
> What is published here is a cleaned-up copy: the identifiers in `vw.sh` are translated to English, and the Home Assistant package is a simplified version of the controller in use. The logic and the screen texts are the same, but **this exact copy has not been run on a phone or in Home Assistant yet.** Test it step by step (`vw.sh status` first).

## What it does

- `phone/vw.sh` runs on the phone. It opens the VW app, reads the screen with `uiautomator dump`, finds buttons by their text, taps them with `input tap` and reports one line:
  `STATUS=charging|plugged|unplugged|unknown|error MESSAGE=… soc 48 power 2.3 lock locked sync 7`
  (`lock` and `sync` come from the header of the app's start page, "Fahrzeug ist verriegelt. Synchronisiert vor 7 Minuten": lock state and age of the car's data in minutes. Useful to read the battery level more often while the car is in use, e.g. for a route planner.)
  Commands: `status`, `start`, `stop`, `current_max`, `current_reduced`, `target <50..100>`, `texts`, `home`, `bg <command>`.
- `homeassistant/packages/ev_app_charging.yaml`: example Home Assistant package with helpers, the script `script.ev_app` (calls `vw.sh` through the *Android Debug Bridge* integration) and a simple controller:
  - **trip**: select 80 % or 100 % → charge now with maximum current. Targets above 80 % are written to the app before every start.
  - **minimum**: below a minimum level → charge to 10 points above it.
  - **solar**: PV surplus above a threshold for 10 minutes → charge with reduced current up to a solar target.
  - HA only stops charging that HA started. There is a "hands off" switch.
- `reconnect/`: `adb-mdns` (Python, standard library only) and `adb-keepalive` with a systemd timer that reopens ADB port 5555 after the phone restarts.
- `phone/ui.sh`: calibration helper (show the screen as text, tap by text or coordinate).

## Requirements

- A spare Android phone, **Android 11 or newer** (for *Wireless debugging* and pairing without a PC), permanently on a charger and on the same network as Home Assistant. Give it a fixed IP (DHCP reservation).
- The VW app installed on it and logged in. Screen lock off, or at least no PIN; the script cannot unlock the phone.
- Home Assistant with the **Android Debug Bridge** integration (`androidtv`), using the Python ADB implementation with an adbkey file.
- Optional: a Linux box with `adb` and systemd for the reconnect timer (any small server, a Proxmox host, a Pi).

## Setup

### 1. Enable ADB over Wi-Fi without a PC

On the phone: *Settings → About phone → Software information →* tap *Build number* 7× → *Developer options → Wireless debugging* on → *Pair device with pairing code*. The screen shows IP:port and a 6-digit code.

From any machine with `adb` in the same network, e.g. the *Terminal & SSH* add-on in Home Assistant (`apk add android-tools`; this is gone after the add-on restarts):

```sh
adb pair <ip>:<pairing-port> <code>          # pairs the key in ~/.android/adbkey
adb connect <ip>:<port shown on the Wireless debugging page>
adb -s <ip>:<port> tcpip 5555                # classic ADB on port 5555, until the next reboot
adb connect <ip>:5555
```

Copy `~/.android/adbkey` and `adbkey.pub` to where Home Assistant and the reconnect timer can read them, for example `/config/adb/adbkey`. Because this key is paired, the phone does not ask "Allow USB debugging?" again. **Never commit this key.**

In scripts run through `bash -s`, add `</dev/null` to every `adb shell …`, otherwise adb eats the rest of the script from stdin.

### 2. Put the scripts on the phone

```sh
adb -s <ip>:5555 push phone/vw.sh /data/local/tmp/vw.sh
adb -s <ip>:5555 push phone/ui.sh /data/local/tmp/ui.sh
adb -s <ip>:5555 push phone/ui_lock.sh /data/local/tmp/ui_lock.sh
adb -s <ip>:5555 shell sh /data/local/tmp/vw.sh status
```

The last command should open the app, go to the charging view and print e.g. `STATUS=plugged MESSAGE=ok soc 48`.

### 3. Home Assistant

1. Add the integration *Android Debug Bridge*: host = phone IP, port 5555, *adbkey* = path of the paired key (e.g. `/config/adb/adbkey`). Rename the media player to `media_player.ev_phone_adb`.
2. Enable packages in `configuration.yaml` if you have not yet:
   ```yaml
   homeassistant:
     packages: !include_dir_named packages
   ```
3. Copy `homeassistant/packages/ev_app_charging.yaml` to `/config/packages/`, replace the placeholders (`sensor.grid_power`, optionally `sensor.vehicle_api_soc`), check the configuration and restart.
4. Test: *Developer tools → Actions →* `script.ev_app` with `command: status`. Then switch on `input_boolean.ev_charging_automation`.

`androidtv.adb_command` only waits about 10 seconds for an answer, but a command takes 15 to 60 seconds. `script.ev_app` therefore starts `vw.sh bg <command>` (detached on the phone) and polls `tail -1 /data/local/tmp/vw.out` every 3 seconds for up to 90 seconds.

### 4. Reconnect after a phone reboot (optional)

`adb tcpip 5555` and *Wireless debugging* do not survive a reboot. After a reboot, *Wireless debugging* has to be switched on again. You can do it by hand, or use an automation app with `WRITE_SECURE_SETTINGS` that sets the global setting `adb_wifi_enabled=1`. It then listens on a random port. `reconnect/adb-keepalive` runs every 5 minutes, finds that port via mDNS (`_adb-tls-connect._tcp`, see `adb-mdns`; Debian's adb has no mDNS support) and runs `adb tcpip 5555` again with the paired key.

```sh
sudo apt install adb python3
sudo install -m 755 reconnect/adb-keepalive reconnect/adb-mdns /usr/local/sbin/
sudo install -d -m 700 /var/lib/adb-keepalive/.android
sudo install -m 600 adbkey adbkey.pub /var/lib/adb-keepalive/.android/
sudo cp reconnect/adb-keepalive.service reconnect/adb-keepalive.timer /etc/systemd/system/
sudo systemctl edit adb-keepalive.service      # set Environment=PHONE_IP=<your phone>
sudo systemctl daemon-reload && sudo systemctl enable --now adb-keepalive.timer
journalctl -u adb-keepalive.service            # prints only when it acted or failed
```

## Calibrating the texts

All app-specific values are in the **CONFIG block at the top of `phone/vw.sh`**: package name, screen texts (regular expressions) and the slider coordinates. To change them without replacing the script, put the changed lines into `/data/local/tmp/vw.conf` on the phone (same `NAME='value'` syntax). That file overrides the defaults.

```sh
adb shell sh /data/local/tmp/ui.sh show                  # what is on screen: text|description|class|checked|clickable|bounds
adb shell sh /data/local/tmp/ui.sh tap "Übersicht"       # tap by text, prints the next screen
adb shell sh /data/local/tmp/vw.sh texts                 # all texts of the current view
```

| Variable | Meaning | Default (German UI) |
|---|---|---|
| `M_START` / `M_STOP` | buttons in the charging view | `Laden starten` / `Laden stoppen` |
| `M_CHARGING` | tile text while charging (fallback) | `Lädt gerade\|Prozent\. Aktiviert` |
| `M_NO_CABLE`, `M_UNPLUGGED` | texts when no cable is connected | `Ladekabel verbinden`, … |
| `M_CHARGE_TILE` | tile on the start page that opens the charging view | `Übersicht Reichweite` |
| `M_DISMISS` | OK button of info dialogs | `Alles klar` |
| `RE_SOC`, `RE_POWER` | where battery level and charging power are read | `Batterieladung: NN Prozent`, `Ladeleistung: N Kilowatt` |
| `SWIPE_TO_SETTINGS`, `M_SETTINGS`, `M_TARGET_ROW`, `M_REDUCED`, `M_SAVE` | path to the charging settings | `Einstellungen. Details öffnen`, `Laden bis`, `Reduzierter AC-Ladestrom`, `Speichern` |
| `SL_Y`, `SL_X0`, `SL_X100` | charge-target slider: y of the track, x of 50 % and of 100 % | `942`, `106`, `830` (1080 px wide screen) |
| `SW_MIN_X`, `SW_TAP_X` | where the reduced-current switch is | `800`, `970` |

The slider is not visible to `uiautomator`; only its value text (`80%`) is. Find the ends of the track with `ui.sh swipe` and watch the value change. `vw.sh target` checks the value after the swipe and reports an error if it does not match.

## Known limitations

- **App updates break it.** New texts or a new layout → `STATUS=unknown` or `error`. The example package then creates a persistent notification. Recalibrate with `vw.sh texts`.
- **The texts are for a German UI.** For other languages, replace every `M_*` and `RE_*` value. The coordinates depend on screen size and resolution.
- **Picture-in-picture blocks taps.** The VW app ignores touches while the Home Assistant app's picture-in-picture window is on top. `vw.sh` therefore force-stops the HA app before opening the VW app and starts it again afterwards. Change `HA_PKG` if another app should come back to the front, or leave it empty.
- **`uiautomator dump` switches off accessibility services.** Every dump sets `accessibility_enabled` to 0. The scripts set it back to 1 if any service is configured. Other tools that dump the UI will not.
- **The app resets the charge target to 80 % after every stop** (with battery care mode on). A higher target only applies to the next session, so the controller writes it again before every start.
- **After a reboot someone has to confirm the "Allow wireless debugging on this network?" popup.** "Always allow" did not stick in our setup, probably because it is remembered per access point (BSSID) and the phone roams between several. Automating the tap with an accessibility-based automation app did not work reliably.
- Every command opens the VW app **visibly** for 10 to 60 seconds. Not great on a phone that is also a wall panel.
- **Several scripts on one phone tap into each other's apps.** If anything else drives the same phone via ADB (a second app, a camera app brought to the front, a debugging session), use the shared lock `phone/ui_lock.sh`: `vw.sh` takes it automatically when it is installed, other scripts source it (`. /data/local/tmp/ui_lock.sh; ui_lock <name> || exit`) or call `sh ui_lock.sh take|release|who|bg` from outside. Usage is described at the top of the file. The lock also gives way to people: while someone touched the screen within the last 45 s (`dumpsys power`), scripts wait, so a wall-mounted phone is not taken over in the middle of normal use (check with `sh ui_lock.sh human`, disable with `UL_QUIET=0`). Do not use `pgrep -f vw.sh` from `adb shell` to detect a running vw.sh: it also matches the `sh -c` wrapper of the adb command itself.
- Screenshots are blocked in the VW app (`screencap` returns an empty image). Only the accessibility tree is available.
- Changing the charging mode while charging had no effect in our tests.
- The controller is deliberately simple: no departure time, no price signal. Extend it as needed.

## Terms of use and disclaimer

Automating the operation of the VW app may conflict with Volkswagen's terms of use for the app and its connected services. This is a grey area. You use this at your own risk, on your own car and your own account. It is not affiliated with or endorsed by Volkswagen AG. "Volkswagen", "VW" and "ID." are trademarks of their respective owners.

The software is provided "as is", without warranty of any kind (see [LICENSE](LICENSE)). The authors are not liable for damage to vehicles, batteries, electrical installations, accounts or anything else. Charging from a household socket puts a long continuous load on the circuit. Have it checked by an electrician.

## Deutsch (Kurzfassung)

Dieses Repo startet und stoppt das Laden eines VW-Elektroautos aus Home Assistant, **ohne Wallbox und ohne funktionierende VW-API**. Ein altes Android-Handy (ab Android 11) mit der VW-App hängt dauerhaft am Ladegerät. Home Assistant bedient die App dort per ADB über WLAN: `vw.sh` öffnet die App, liest die Ansicht mit `uiautomator dump` und tippt „Laden starten“ bzw. „Laden stoppen“ an. Ladeziel und reduzierten Ladestrom stellt es über die Einstellungen der App ein.

Die Standardtexte im Konfigurationsblock oben in `phone/vw.sh` passen zur **deutschen** Oberfläche der App (Stand Oktober 2026). Nach einem App-Update müssen sie eventuell neu eingestellt werden (`vw.sh texts`, `ui.sh show`, Überschreiben per `/data/local/tmp/vw.conf`). Die Einrichtung ohne PC geht über *Entwickleroptionen → Debugging über WLAN → Gerät über einen Kopplungscode koppeln* und `adb pair`, etwa aus dem Add-on „Terminal & SSH“ in Home Assistant.

Bedienen mehrere Skripte dasselbe Handy, nehmen sie vorher die gemeinsame Sperre `phone/ui_lock.sh` (`vw.sh` tut das selbst, sobald die Datei auf dem Handy liegt). Wurde das Handy in den letzten 45 s berührt, warten die Skripte, damit niemand mitten in der Bedienung unterbrochen wird. Die Grenzen stehen oben unter *Known limitations*. Nach jedem Neustart des Handys muss jemand das Popup „Debugging über WLAN zulassen?“ bestätigen, und die App setzt das Ladeziel nach jedem Stopp auf 80 % zurück. Die automatisierte Bedienung der App ist bei den Nutzungsbedingungen von VW eine Grauzone. Nutzung auf eigene Gefahr, ohne Gewähr.

## License

[MIT](LICENSE)
