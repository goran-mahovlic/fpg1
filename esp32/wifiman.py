import network
import time

def read_profiles():
  with open("wifiman.conf") as f:
    lines = f.readlines()
  profiles = {}
  for line in lines:
    if line.find(":")>=0:
      ssid, password = line.strip("\n").split(":")
      profiles[ssid] = password
  return profiles

wlan_sta = network.WLAN(network.STA_IF)

def get_connection():
  """return a working WLAN(STA_IF) instance or None"""

  # First check if there already is any connection:
  if wlan_sta.isconnected():
    return wlan_sta

  connected = False
  try:
    # ESP connecting to WiFi takes time, wait a bit and try again:
    time.sleep(3)
    if wlan_sta.isconnected():
        return wlan_sta

    # Read known network profiles from file
    profiles = read_profiles()

    # Search WiFis in range
    wlan_sta.active(True)
    networks = wlan_sta.scan()

    AUTHMODE = {0: "open", 1: "WEP", 2: "WPA-PSK", 3: "WPA2-PSK", 4: "WPA/WPA2-PSK"}
    scanned_ssids = []
    for ssid, bssid, channel, rssi, authmode, hidden in sorted(networks, key=lambda x: x[3], reverse=True):
      ssid = ssid.decode('utf-8')
      scanned_ssids.append(ssid)
      encrypted = authmode > 0
      print("ssid: %s chan: %d rssi: %d authmode: %s" % (ssid, channel, rssi, AUTHMODE.get(authmode, '?')))
      if ssid in profiles: # connect only to configured ssids
        if encrypted:
          connected = do_connect(ssid, profiles[ssid])
        else:
          connected = do_connect(ssid, None)
      if connected:
        break

    # Try direct connection to configured networks not found in scan
    if not connected:
      for ssid, password in profiles.items():
        if ssid not in scanned_ssids:
          print("Trying direct connect to:", ssid)
          connected = do_connect(ssid, password)
          if connected:
            print("Direct connect successful!")
            break

  except OSError as e:
    print("exception", str(e))

  return wlan_sta

def do_connect(ssid, password):
  wlan_sta.active(True)
  if wlan_sta.isconnected():
    return True  # Already connected - return True, not None
  print("Connecting to:", ssid)
  wlan_sta.connect(ssid, password)
  # Extended timeout for hidden SSID (20 seconds instead of 10)
  for retry in range(200):
    connected = wlan_sta.isconnected()
    if connected:
      print("Connected! IP:", wlan_sta.ifconfig()[0])
      break
    time.sleep(0.1)
  if not connected:
    print("Connection timeout for:", ssid)
  return connected

get_connection()
