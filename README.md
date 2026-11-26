# relay_tracking geoip data

IP to location (`IP_GEO=1`) and IP to network owner (`IP_ASN=1`) data for the relay_tracking collectors,
rebuilt from [DB-IP](https://db-ip.com)'s free "IP to City Lite" and "IP to ASN Lite" databases by
`tools/dbip-convert.py` on the main branch.

IP Geolocation by DB-IP, licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
Changes: coordinates and continent dropped, neighbouring ranges with the same location merged, range starts
only (see the converter for the format).
