#!/bin/bash
# CX3566-Z post-boot function test — run as root on the card system.
# Prints a full report to the console; nothing is modified.
echo "########## SYSTEM ##########"
hostname
uname -a
grep -E "BOARD|VERSION|KERNEL" /etc/armbian-release 2>/dev/null

echo "########## ETHERNET ##########"
ip -brief addr
GW=$(ip route 2>/dev/null | awk '/default/{print $3; exit}')
echo "gateway: ${GW:-none}"
[ -n "$GW" ] && ping -c 2 -W 2 "$GW" | tail -2
ping -c 2 -W 3 223.5.5.5 | tail -2
for n in /sys/class/net/e*; do
  [ -e "$n" ] && echo "$(basename $n): state=$(cat $n/operstate 2>/dev/null) speed=$(cat $n/speed 2>/dev/null)"
done

echo "########## USB ##########"
if command -v lsusb >/dev/null; then lsusb; lsusb -t; else echo "lsusb missing"; ls /sys/bus/usb/devices/; fi
echo "--- usb devices in sysfs ---"
for d in /sys/bus/usb/devices/*/; do
  [ -f "$d/idVendor" ] && echo "$(basename $d): $(cat $d/idVendor):$(cat $d/idProduct) $(cat $d/product 2>/dev/null)"
done
echo "--- usb errors in dmesg ---"
dmesg | grep -iE "usb|xhci|ehci|ohci" | grep -iE "error|fail|timeout|unable|over-current|device not" | head -12
echo "--- usb controllers ---"
dmesg | grep -iE "xhci|ehci|ohci" | head -8

echo "########## WIFI ##########"
echo "--- net devices ---"
ls /sys/class/net/
ls /sys/class/ieee80211/ 2>/dev/null
echo "--- aic modules ---"
lsmod | grep -i aic || echo "no aic module loaded"
echo "--- aic/wlan dmesg ---"
dmesg | grep -iE "aic|8800|wlan|sdio" | tail -25
echo "--- iw scan ---"
if command -v iw >/dev/null; then
  iw dev
  ip link set wlan0 up 2>/dev/null
  sleep 2
  iw dev wlan0 scan 2>&1 | grep -E "SSID:|signal:" | head -14
else
  echo "iw missing"
fi
rfkill list 2>/dev/null

echo "########## NETWORK MANAGER ##########"
for c in nmcli nmtui iw wpa_supplicant; do command -v $c >/dev/null && echo "$c: yes" || echo "$c: NO"; done
systemctl is-active NetworkManager 2>/dev/null | sed 's/^/NetworkManager: /'
systemctl is-active systemd-networkd 2>/dev/null | sed 's/^/systemd-networkd: /'

echo "########## RECENT ERRORS ##########"
dmesg | grep -iE "error|failed|firmware" | tail -15
echo "########## TEST DONE ##########"
