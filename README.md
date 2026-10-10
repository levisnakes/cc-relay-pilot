# CC Relay Pilot

Fly a Create Aeronautics ship that runs entirely on **Redstone Relays**, from a **Linked Typewriter** on a second computer. The two computers talk over **Ender Modems**, so the controller can be anywhere.

- **Up speed** 0-9 (9 fastest), sent as a redstone strength. It stays where you set it.
- **Two propellers**, each forward / reverse / off through a Directional Gearshift, give every move: forward, backward, turn on the spot, and arcs.
- **Bottom signal**: the ship computer's bottom side gives a constant signal; **Q** switches it off (and on again).

## Install

Run this on **both** computers:

```
wget https://raw.githubusercontent.com/levisnakes/cc-relay-pilot/main/startup.lua startup.lua
reboot
```

The first time, it asks whether the computer is the **S**hip or the **C**ontroller. To change that later, run `startup ship` or `startup controller`. On every boot it downloads the newest version and runs it.

## Hardware

**Ship computer**
- an Ender Modem (any wireless modem works)
- Redstone Relays on a wired modem network (right-click each modem to connect it). With Redstone Links on the relay sides, one relay can drive four or more things.
- its **bottom** side gives the constant signal (change `BOTTOM_SIDE` in `ship_settings.lua` if you need another side).

**Controller computer**
- an Ender Modem
- the Linked Typewriter (wired modem or touching it)
- optional: an Advanced Monitor (at least 51x19 characters) shows the same screens, with touch.

## First time

1. Start both computers. The ship computer shows a **pairing code**.
2. On the controller: **P (Pair)**, type the code, Enter. The code changes after each pairing; the ship stays paired through reboots.
3. **L (Lift setup)**: tap the relay side(s) that carry the up speed. Test it with + / -. **X** switches the signal between "as is" (up speed 9 = strength 9) and "stretched" (9 = strength 15).
4. **S (Propeller setup)**: four short steps. For each one, switch relay sides on until that propeller pushes that way, then press Enter:
   left forward, left backward, right forward, right backward.
   If A turns the ship the wrong way afterwards, press **X (Swap left/right)** on the summary.
5. **D (Drive)**.

## Keys (on the typewriter)

| Key | Does |
|---|---|
| W / S | both propellers forward / reverse while held |
| A / D | turn on the spot (one propeller each way) while held |
| W+A, W+D, S+A, S+D | arc: the propeller on the inside of the turn stops |
| Space / Left Shift | up speed one step faster / slower |
| 0-9 | up speed straight to that number |
| Q | bottom signal off; press again for on |

Space, Shift and Q work from any screen. Change keys in **K (Keybinds)**; check what arrives in **T (Typewriter test)**.

**Q and 0-9 need a binding on the typewriter.** The typewriter only sends keys that are bound to a Redstone Link frequency. W A S D, Space and Shift come bound; for Q and the digits, sneak + right-click the typewriter and give them any frequency.

On the controller's screen you can also tap the up-speed bar, [-] / [+], and the Q Bottom button. On the keyboard, + / - change the up speed and M goes back to the menu.

## Safety

- **Link lost:** if the ship hears nothing from the controller for 1 second (chunk unloaded, controller off), the propellers stop. The up speed and bottom signal stay where they are, so the ship doesn't drop.
- **Ship reboot or server restart:** the ship computer puts the up speed and bottom signal back exactly as they were before it does anything else.
- **Other players:** only paired controllers are obeyed. Each message carries a secret key, and wrong pairing codes get no answer. 5 wrong codes in a minute from one computer lock it out.
- **Gearshifts:** sides switch off before others switch on, so a gearshift is never told forward and reverse at the same moment.

## Ship computer screen

The ship computer's screen shows:
- the pairing code and which controllers are paired
- the up speed, both propellers and the bottom signal
- any relay errors

Its buttons (also keys):

| Key | Does |
|---|---|
| B | bottom signal on/off |
| + / - | up speed |
| S | stop the propellers |
| N | new pairing code |
| U | unpair every controller |

## Logs

`ship.log` and `controller.log` record everything (the run before is kept as `.log.old`). To share one:

```
pastebin put ship.log
```
