#!/usr/bin/env python3
"""
Makes docs/tour/Checklist.pdf from docs/tour/README.md and its screenshots: landscape Letter pages, each
split in two like two pages printed side by side. The left half is the tour, one screen per page with its
caption, the source files behind that screen (a short summary over each file name and its line range, worked
out from the code as it is now) and a box to tick; the right half is ruled for handwritten notes.
Needs Python with reportlab and Pillow (pip3 install reportlab pillow).
Usage: tour-checklist.py [path to docs/tour]
"""
import io
import os
import re
import sys

from PIL import Image
from reportlab.lib.colors import Color, black
from reportlab.lib.pagesizes import landscape, letter
from reportlab.lib.utils import ImageReader, simpleSplit
from reportlab.pdfgen import canvas

TOUR = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/src/APRSERJi/docs/tour")
ROOT = os.path.abspath(os.path.join(TOUR, "..", ".."))
OUT = os.path.join(TOUR, "Checklist.pdf")

# The code behind each screen, by the screenshot's name: (summary, file, the text of the block's first line).
# The block runs from that line to its closing brace. A fourth item, when there, is text on a line above to
# start from instead (for a block inside a larger one). Line numbers are found when the PDF is made.
APP = "App/APRSERJiApp.swift"
CODE = {
    "map": [("The Map tab: the map with its overlays, station bubble and credits", APP, "private var stationMap: some View"),
            ("The MapKit map: OSM tiles, station markers, labels, tracks and layers", "App/OSMMap.swift", "struct OSMMap: NativeMapRepresentable"),
            ("The floating bar: connection status, GPS, go-to and settings buttons", APP, "private var mapOverlay: some View")],
    "map-settings": [("The map settings panel: version line, tiles, layers, ranges", APP, "private var mapControls: some View"),
                     ("Callsign, server, port, sending, passcode and Connect", APP, "private var connectionSettings: some View"),
                     ("The view filter and the always-show callsigns", "App/ViewFilter.swift", "struct ViewSettingsRow: View")],
    "stations": [("The station list: search, sort and the All/Stations/Weather/Objects filter", "App/StationListView.swift", "struct StationListView: View"),
                 ("One row: symbol, callsign, distance, bearing and comment", "App/StationListView.swift", "private struct StationRow: View")],
    "station-weather": [("The station details page", "App/StationListView.swift", "struct StationDetailView: View"),
                        ("The weather readings: wind, temperature, rain, humidity, pressure", "App/StationListView.swift", "private func weather(_ s: StationDetail)")],
    "station-mobile": [("The header: symbol, comment, nickname and the action buttons", "App/StationListView.swift", "private func header(_ s: StationDetail)"),
                       ("Position: coordinates, grid square, distance and bearing", "App/StationListView.swift", "private func position(_ s: StationDetail)"),
                       ("Movement: course, speed and altitude", "App/StationListView.swift", "private func motion(_ s: StationDetail)")],
    "messages": [("A conversation: messages, delivery status, route, compose and Queue", "App/ChatView.swift", "struct ChatView: View")],
    "bulletins": [("NWS warnings, APRS bulletins and ANSRVR announcements", "App/BulletinsView.swift", "struct BulletinsView: View"),
                  ("Fetches the NWS alerts for your area", "App/NWSWarnings.swift", "final class NWSWarnings: ObservableObject")],
    "setup-beacon": [("Beacon on/off, status, position source, report and timing", "App/BeaconView.swift", "struct BeaconSections: View"),
                     ("Hands the beacon settings and position to the APRS engine", "App/BeaconView.swift", "enum BeaconSync")],
    "setup-status": [("Status reports and telemetry", "App/ReportsView.swift", "struct StatusTelemetrySections: View")],
    "setup-ports": [("Radio ports, software modems, IGate and digipeater", "App/PortsView.swift", "struct PortsSection: View"),
                    ("Adding or editing one port", "App/PortsView.swift", "private struct PortEditor: View")],
    "setup-gps": [("GPS source: Core Location, serial or network NMEA, gpsd", "App/StationInputs.swift", "struct GpsSourceSection: View"),
                  ("The satellite sky plot", "App/StationInputs.swift", "struct SkyPlot: View")],
    "setup-cat": [("Virtual radio (CAT) on/off and where programs connect", "App/CatRig.swift", "struct CatRigSection: View"),
                  ("Channels and CHIRP import", "App/Channels.swift", "struct ChannelsSection: View"),
                  ("Kenwood and Hamlib commands, and APRSERJi's own M commands", "App/CatRig.swift", "final class VirtualRig: ObservableObject")],
    "setup-weather": [("Weather station source, Tempest, weather reports and CWOP", "App/StationInputs.swift", "struct WeatherStationSections: View"),
                      ("Reads the weather inputs", "App/StationInputs.swift", "final class WeatherStation: ObservableObject")],
    "setup-services": [("APRS server for other programs, UDP input and syslog", "App/StationInputs.swift", "struct ServicesSections: View")],
    "setup-layers": [("The map layers switches", "App/SetupView.swift", 'Toggle("Paths of travel"', "Section {")],
    "setup-reference": [("Boundaries and roads: online, or files you import", "App/ReferenceLayers.swift", "struct ReferenceLayersSection: View"),
                        ("Keeps the imported boundary and road files", "App/ReferenceLayers.swift", "final class ReferenceStore: ObservableObject")],
    "setup-offline": [("Downloading map tiles for offline use", "App/TileCache.swift", "struct OfflineMapsSection: View"),
                      ("The tile cache on disk", "App/TileCache.swift", "enum TileCache")],
    "setup-tracklog": [("Track logging settings", "App/TrackLogger.swift", "struct TrackLogSection: View"),
                       ("Writes the GPX track logs", "App/TrackLogger.swift", "final class TrackLogger")],
    "setup-watchalerts": [("Watch list alerts settings", "App/TrackLogger.swift", "struct WatchAlertSection: View"),
                          ("Alerts when a watched station comes near", "App/TrackLogger.swift", "final class WatchAlerts")],
    "setup-fcc": [("The FCC callsign database: download and status", "App/Lookup/FCCDatabase.swift", "struct FCCDatabaseSection: View"),
                  ("Downloads and searches the FCC license data", "App/Lookup/FCCDatabase.swift", "enum FCCDatabase")],
    "setup-display": [("Units, notifications and the version line", "App/SetupView.swift", 'Toggle("Metric units"', "Section {"),
                      ("The app's name, version and build", APP, "enum AppInfo")],
    "tools": [("The Tools list", "App/ToolsView.swift", "struct ToolsView: View"),
              ("Each Tools page: title and icon", "App/ToolsView.swift", "enum ToolPage: String, CaseIterable, Hashable")],
    "tools-objects": [("Objects and items you send", "App/ReportsView.swift", "struct ObjectsView: View"),
                      ("Editing an object or item", "App/ReportsView.swift", "private struct ObjectEditor: View"),
                      ("Scheduled bulletins", "App/ReportsView.swift", "struct ScheduledBulletinsSection: View")],
    "tools-beacon-journal": [("The beacon journal: what was sent, when and why", "App/ToolsView.swift", "struct BeaconJournalView: View")],
    "tools-packet-monitor": [("The packet monitor: every packet in and out, with filters", "App/ToolsView.swift", "struct PacketMonitorView: View")],
    "tools-email": [("Send email through the APRS email gateway", "App/ToolsView.swift", "struct EmailView: View")],
    "tools-frequencies": [("Frequencies that stations advertise", "App/ToolsView.swift", "struct FrequencyView: View")],
    "tools-platforms": [("Radios and software that stations use", "App/ToolsView.swift", "struct PlatformsView: View")],
    "tools-dx": [("RF DX: the farthest stations heard on the radio", "App/ToolsView.swift", "struct DxView: View")],
    "tools-history": [("Station history list", "App/ToolsView.swift", "struct HistoryView: View"),
                      ("One station's history, track and telemetry graphs", "App/ToolsView.swift", "struct HistoryDetail: View")],
    "tools-satellites": [("Satellites: elements, tracking and passes", "App/ToolsView.swift", "struct SatellitesView: View")],
    "tools-direction-finding": [("Direction finding: bearings and where they cross", "App/ToolsView.swift", "struct DirectionFindingView: View")],
    "tools-digital-logs": [("Digital-mode logs on the map", "App/ToolsView.swift", "struct DigitalLogsView: View"),
                           ("Reads FT8, JS8Call and JT65 logs", "App/MapExtras.swift", "enum DigitalLogParser")],
    "tools-imported-layers": [("Imported GPX and OSM layers", "App/ToolsView.swift", "struct ImportedLayersView: View"),
                              ("Reads GPX and OSM files", "App/MapExtras.swift", "final class LayerParser: NSObject, XMLParserDelegate")],
    "multitrack": [("MultiTrack: a map for each of up to 8 stations", "App/MultiTrackView.swift", "struct MultiTrackView: View")],
    "watch-messages": [("The Watch's Messages page", "Watch/MessagesPage.swift", "struct MessagesPage: View"),
                       ("One conversation in the list", "Watch/MessagesPage.swift", "private struct ConversationRow: View")],
    "watch-conversation": [("A conversation on the Watch", "Watch/MessagesPage.swift", "struct ConversationView: View")],
    "watch-reply": [("Reply: dictation, Scribble or quick replies", "Watch/MessagesPage.swift", "struct ReplyView: View"),
                    ("Sends the reply to the iPhone", "Watch/WatchStore.swift", "func send(_ command: WatchCommand")],
    "watch-nearby": [("Nearby stations on the Watch", "Watch/StationsPage.swift", "struct StationsPage: View"),
                     ("One station: arrow, distance and direction", "Watch/StationsPage.swift", "private struct StationRow: View")],
    "watch-station": [("A station's details on the Watch", "Watch/StationsPage.swift", "struct StationDetailPage: View")],
    "watch-map": [("The Watch map: zoom buttons, the right-edge strip and the version line", "Watch/MapPage.swift", "struct MapPage: View"),
                  ("You and the nearest stations on the map", "Watch/MapPage.swift", "private struct StationsMap: View"),
                  ("Turns edge swipes into page changes", "Watch/APRSERJiWatchApp.swift", "struct PageEdge: View")],
    "watch-beacon": [("Beacon status and Beacon now on the Watch", "Watch/BeaconPage.swift", "struct BeaconPage: View"),
                     ("The iPhone side: sends the Watch its data and runs Beacon now", "App/WatchCompanion.swift", "final class WatchCompanion: NSObject")],
}


def braces(line):
    """The change in brace depth over one line of Swift, skipping strings and comments."""
    depth, i, in_string = 0, 0, False
    while i < len(line):
        ch = line[i]
        if in_string:
            if ch == "\\":
                i += 1
            elif ch == '"':
                in_string = False
        elif line.startswith("//", i):
            break
        elif ch == '"':
            in_string = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
        i += 1
    return depth


_files = {}


def code_range(path, first, above=None):
    """Line numbers (start, end) of the block whose first line holds [first], or None."""
    if path not in _files:
        full = os.path.join(ROOT, path)
        _files[path] = open(full, encoding="utf-8").read().split("\n") if os.path.exists(full) else []
    lines = _files[path]
    start = next((i for i, line in enumerate(lines) if first in line), None)
    if start is None:
        return None
    if above:
        start = next((i for i in range(start, -1, -1) if above in lines[i]), start)
    depth, opened = 0, False
    for i in range(start, len(lines)):
        change = braces(lines[i])
        if "{" in lines[i]:
            opened = True
        depth += change
        if opened and depth <= 0:
            return start + 1, i + 1
    return start + 1, len(lines)


def code_refs(image_path):
    """[(summary, "file  lines a–b")] for one screenshot."""
    refs = []
    for entry in CODE.get(os.path.splitext(os.path.basename(image_path))[0], []):
        summary, path, first = entry[:3]
        found = code_range(path, first, entry[3] if len(entry) > 3 else None)
        if found:
            refs.append((summary, f"{path}   lines {found[0]}–{found[1]}"))
    return refs
W, H = landscape(letter)          # 792 x 612 points
M = 30                            # margin
MID = W / 2                       # the fold between the two halves
LEFT, LEFT_W = M, MID - M - 16    # the tour column
RIGHT, RIGHT_W = MID + 16, W - MID - 16 - M
GRAY, LIGHT = Color(0.35, 0.35, 0.35), Color(0.8, 0.8, 0.8)


def read_tour():
    """Title, intro paragraph, and [(platform, [(image path, caption)])] from README.md."""
    text = open(os.path.join(TOUR, "README.md"), encoding="utf-8").read()
    title = re.search(r"^# (.+)$", text, re.M).group(1)
    intro = next(p.strip() for p in text.split("\n\n")[1:] if p.strip() and not p.startswith(("#", "[", "<")))
    intro = intro.replace("`", "")
    sections = []
    for match in re.finditer(r"^## (.+?)$(.*?)(?=^## |\Z)", text, re.M | re.S):
        shots = re.findall(r'<img src="([^"]+)"[^>]*alt="([^"]*)"', match.group(2))
        shots = [(os.path.join(TOUR, src), alt.replace("&amp;", "&")) for src, alt in shots
                 if os.path.exists(os.path.join(TOUR, src))]
        if shots:
            sections.append((match.group(1).strip(), shots))
    return title, intro, sections


def picture(path, max_w, max_h):
    """The screenshot scaled for print (about 200 dpi in the space it gets) and recompressed."""
    image = Image.open(path).convert("RGB")
    scale = min(max_w / image.width, max_h / image.height)
    w, h = image.width * scale, image.height * scale
    pixels = min(1.0, (w / 72 * 200) / image.width)
    if pixels < 1:
        image = image.resize((max(1, int(image.width * pixels)), max(1, int(image.height * pixels))), Image.LANCZOS)
    data = io.BytesIO()
    image.save(data, "JPEG", quality=80, optimize=True)
    data.seek(0)
    return ImageReader(data), w, h


def notes_column(c):
    """The right half: a Notes heading and ruled lines to write on."""
    c.setFont("Helvetica-Bold", 12)
    c.setFillColor(black)
    c.drawString(RIGHT, H - M - 12, "Notes")
    c.setStrokeColor(LIGHT)
    c.setLineWidth(0.5)
    y = H - M - 40
    while y > M + 20:
        c.line(RIGHT, y, RIGHT + RIGHT_W, y)
        y -= 22
    # The fold between the halves.
    c.setDash(2, 3)
    c.line(MID, M, MID, H - M)
    c.setDash()


def footer(c, page, pages):
    c.setFont("Helvetica", 8)
    c.setFillColor(GRAY)
    c.drawRightString(W - M, M - 14, f"Page {page} of {pages}")
    c.drawString(LEFT, M - 14, "APRSERJi tour checklist")


def tick_box(c, y):
    """A box to tick, with room for the date and initials."""
    c.setStrokeColor(black)
    c.setLineWidth(0.8)
    c.rect(LEFT, y - 2, 11, 11)
    c.setFont("Helvetica", 10)
    c.setFillColor(black)
    c.drawString(LEFT + 17, y, "Checked")
    c.drawString(LEFT + 80, y, "Date ____________")
    c.drawString(LEFT + 200, y, "Initials ________")


def wrapped(c, text, x, y, width, font, size, leading):
    c.setFont(font, size)
    for line in simpleSplit(text, font, size, width):
        c.drawString(x, y, line)
        y -= leading
    return y


def main():
    title, intro, sections = read_tour()
    total = sum(len(shots) for _, shots in sections)
    pages = 1 + total
    c = canvas.Canvas(OUT, pagesize=(W, H))
    c.setTitle("APRSERJi tour checklist")
    c.setAuthor("KC9KKO")

    # Page 1: what the tour is and where each device starts.
    c.setFillColor(black)
    y = wrapped(c, title + " — checklist", LEFT, H - M - 16, LEFT_W, "Helvetica-Bold", 16, 20) - 6
    y = wrapped(c, intro, LEFT, y, LEFT_W, "Helvetica", 10.5, 14) - 10
    y = wrapped(c, "Each page shows one screen and the source files behind it, with their line numbers. Compare the "
                   "screen with the app, tick the box when it matches, and write anything to fix or change in the "
                   "Notes column on the right.", LEFT, y, LEFT_W, "Helvetica", 10.5, 14) - 16
    c.setFont("Helvetica-Bold", 11)
    c.drawString(LEFT, y, "Contents")
    y -= 18
    start = 2
    c.setFont("Helvetica", 10.5)
    for platform, shots in sections:
        c.drawString(LEFT + 8, y, platform)
        c.drawRightString(LEFT + LEFT_W - 60, y, f"{len(shots)} screens")
        c.drawRightString(LEFT + LEFT_W, y, f"page {start}")
        start += len(shots)
        y -= 16
    c.setFont("Helvetica-Bold", 10.5)
    c.drawString(LEFT + 8, y, "Total")
    c.drawRightString(LEFT + LEFT_W - 60, y, f"{total} screens")
    y -= 30
    tick_box(c, y)
    c.setFont("Helvetica", 8)
    c.setFillColor(GRAY)
    c.drawString(LEFT + 17, y - 14, "(the whole tour)")
    notes_column(c)
    footer(c, 1, pages)
    c.showPage()

    # One page per screen.
    page = 1
    for platform, shots in sections:
        for number, (path, caption) in enumerate(shots, 1):
            page += 1
            c.setFont("Helvetica", 9)
            c.setFillColor(GRAY)
            c.drawString(LEFT, H - M - 9, f"{platform}  ·  {number} of {len(shots)}")
            c.drawRightString(LEFT + LEFT_W, H - M - 9, os.path.basename(path))
            c.setFillColor(black)
            y = wrapped(c, caption, LEFT, H - M - 30, LEFT_W, "Helvetica-Bold", 12, 15) - 6
            refs = code_refs(path)
            code_height = (16 + 24 * len(refs)) if refs else 0
            top, bottom = y, M + 34 + code_height
            image, w, h = picture(path, LEFT_W, top - bottom)
            x = LEFT + (LEFT_W - w) / 2
            c.drawImage(image, x, top - h, w, h)
            c.setStrokeColor(LIGHT)
            c.setLineWidth(0.5)
            c.rect(x, top - h, w, h)
            if refs:
                # The code behind this screen: a summary over each file name and its lines.
                y = top - h - 16   # right under the picture
                c.setFont("Helvetica-Bold", 8.5)
                c.setFillColor(black)
                c.drawString(LEFT, y, "Code")
                y -= 12
                for summary, where in refs:
                    c.setFont("Helvetica", 8.5)
                    c.setFillColor(black)
                    c.drawString(LEFT + 6, y, simpleSplit(summary, "Helvetica", 8.5, LEFT_W - 6)[0])
                    c.setFont("Courier", 8)
                    c.setFillColor(GRAY)
                    c.drawString(LEFT + 6, y - 10, where)
                    y -= 24
            tick_box(c, M + 10)
            notes_column(c)
            footer(c, page, pages)
            c.showPage()
    c.save()
    print(f"Wrote {OUT}: {pages} pages, {os.path.getsize(OUT) / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
