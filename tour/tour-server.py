#!/usr/bin/env python3
"""
A tiny stand-in for an APRS-IS server, used by tour.sh for the screenshot tour.

It accepts any login as verified and sends made-up stations around Goose Lake Prairie State Natural Area
(Grundy County, Illinois): mobiles that move, a weather station, a digipeater, an IGate, objects, a bulletin,
telemetry and messages to the logged-in callsign. Messages the app sends are acknowledged.
The demo callsigns use the N0 + four letters pattern, which is never issued, so none belongs to a real person.
Usage: tour-server.py [port]     (default 14590, listens on 127.0.0.1 only)
"""
import math, socket, sys, threading, time
from datetime import datetime, timezone

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 14590
HOME = (41.36750, -88.29722)   # Goose Lake Prairie State Natural Area


def lat_text(lat):
    d = int(abs(lat)); m = (abs(lat) - d) * 60
    return f"{d:02d}{m:05.2f}{'N' if lat >= 0 else 'S'}"


def lon_text(lon):
    d = int(abs(lon)); m = (abs(lon) - d) * 60
    return f"{d:03d}{m:05.2f}{'E' if lon >= 0 else 'W'}"


def position(call, lat, lon, table, symbol, text, path="APRS,TCPIP*,qAC,T2TOUR"):
    return f"{call}>{path}:={lat_text(lat)}{table}{lon_text(lon)}{symbol}{text}"


def message(sender, to, text, number=None):
    return f"{sender}>APRS,TCPIP*,qAC,T2TOUR::{to:<9}:{text}" + (f"{{{number}" if number else "")


def static_packets(me):
    stamp = datetime.now(timezone.utc).strftime("%d%H%Mz")
    return [
        position("N0DIGI-10", 41.3570, -88.4210, "/", "#", "145.390MHz T107 -060 PHG5360/W2, Morris digipeater",
                 "APN391,WIDE2-1,qAR,N0IGAT-10"),
        position("N0IGAT-10", 41.4330, -88.1950, "I", "&", "RX-only IGate, Channahon"),
        position("N0HOME", 41.3300, -88.2200, "/", "-", "146.520MHz Home station, simplex"),
        f"N0WXST>APRS,TCPIP*,qAC,T2TOUR:@{stamp}{lat_text(41.4050)}/{lon_text(-88.2480)}_270/008g014t046r000p002P001h71b10162 Davis Vantage Pro2",
        f"N0TOUR-7>APDR16,WIDE1-1,qAR,N0IGAT-10:={lat_text(41.3712)}/{lon_text(-88.2905)}[045/002/A=000525 Hiking the tallgrass trail",
        f"N0DEMO>APRS,TCPIP*,qAC,T2TOUR:;CABIN    *{stamp}{lat_text(41.3655)}/{lon_text(-88.3030)}hCragg Cabin open house 10am-2pm",
        f"N0DEMO>APRS,TCPIP*,qAC,T2TOUR:)VISITOR!{lat_text(41.3698)}/{lon_text(-88.2952)}?Visitor center, talk-in 146.52",
        f"N0DIGI-10>APRS,TCPIP*,qAC,T2TOUR::BLN1     :Grundy County ARC meets Tuesday 7pm, Morris library",
        f"N0DIGI-10>APRS,TCPIP*,qAC,T2TOUR::BLN2     :Skywarn net Thursday 8pm on 145.390",
        f"N0HOME>APRS,TCPIP*,qAC,T2TOUR:>Station up 24/7, Elecraft K4",
        f"N0HOME>APRS,TCPIP*,qAC,T2TOUR::N0HOME   :PARM.Battery,Temp,Light",
        f"N0HOME>APRS,TCPIP*,qAC,T2TOUR::N0HOME   :UNIT.Volts,DegF,Lux",
        f"N0HOME>APRS,TCPIP*,qAC,T2TOUR::N0HOME   :EQNS.0,0.1,0,0,1,0,0,10,0",
        message("N0DEMO-9", me, "Heading to Goose Lake Prairie, ETA 20 minutes", "1"),
        message("N0TOUR-7", me, "QSL, on the tallgrass trail", "1"),
    ]


def mobile(t):
    """N0DEMO-9 drives a loop around the park; N0TRUK-14 heads west on I-80."""
    angle = (t / 240.0) * 2 * math.pi
    lat = HOME[0] + 0.03 * math.sin(angle)
    lon = HOME[1] + 0.045 * math.cos(angle)
    course = int((math.degrees(-angle) + 360) % 360)
    car = f"N0DEMO-9>APK004,WIDE1-1,qAR,N0IGAT-10:={lat_text(lat)}/{lon_text(lon)}>{course:03d}/038Mobile, monitoring 146.52"
    tlon = -88.10 - (t % 900) * 0.0004
    truck = f"N0TRUK-14>APRS,TCPIP*,qAC,T2TOUR:={lat_text(41.4930)}/{lon_text(tlon)}k270/062On I-80 westbound"
    return [car, truck]


def serve(conn):
    def send(line):
        conn.sendall((line + "\r\n").encode())
    try:
        send("# aprsc 2.1.14 tour server")
        conn.settimeout(10)
        login = conn.makefile("r", encoding="utf-8", errors="replace").readline()
        parts = login.split()
        me = parts[1].upper() if len(parts) > 1 else "N0CALL"
        send(f"# logresp {me} verified, server T2TOUR")
        for line in static_packets(me):
            send(line); time.sleep(0.05)
        conn.settimeout(0.5)
        reader = conn.makefile("r", encoding="utf-8", errors="replace")
        start = time.time(); last_move = 0; last_keep = time.time(); telemetry = 0; sent_parking = False
        buffer = ""
        while True:
            now = time.time()
            if now - last_move >= 5:
                for line in mobile(now - start):
                    send(line)
                last_move = now
                telemetry += 1
                send(f"N0HOME>APRS,TCPIP*,qAC,T2TOUR:T#{telemetry % 1000:03d},{128 + telemetry % 6},{60 + telemetry % 9},{40 + (telemetry * 7) % 50},000,000,00000000")
            if not sent_parking and now - start > 25:
                send(message("N0DEMO-9", me, "Parking now, by the cabin", "2"))
                sent_parking = True
            if now - last_keep >= 20:
                send("# tour server keepalive"); last_keep = now
            try:
                chunk = conn.recv(4096).decode("utf-8", "replace")
                if not chunk:
                    break
                buffer += chunk
                while "\n" in buffer:
                    line, buffer = buffer.split("\n", 1)
                    line = line.strip()
                    # Acknowledge messages the app sends: CALL>...::PEER     :text{id
                    if "::" in line and "{" in line and not line.startswith("#"):
                        sender = line.split(">", 1)[0]
                        body = line.split("::", 1)[1]
                        peer, text = body[:9].strip(), body[10:]
                        number = text.rsplit("{", 1)[1].split("}")[0]
                        if not text.startswith(("ack", "rej")):
                            time.sleep(1)
                            send(f"{peer}>APRS,TCPIP*,qAC,T2TOUR::{sender:<9}:ack{number}")
            except socket.timeout:
                pass
    except (OSError, IndexError):
        pass
    finally:
        conn.close()


def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", PORT))
    server.listen(8)
    print(f"tour server on 127.0.0.1:{PORT}", flush=True)
    while True:
        conn, _ = server.accept()
        threading.Thread(target=serve, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
