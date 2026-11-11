import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    // ── Settings (from plugin data) ───────────────────────────────────────────
    readonly property int refreshSecs: pluginData.refreshSecs || 10
    readonly property int staleSecs: pluginData.staleSecs || 180
    readonly property bool showPowerInBar: pluginData.showPowerInBar !== undefined ? pluginData.showPowerInBar : true
    readonly property string dbHost: pluginData.dbHost || "127.0.0.1"
    readonly property string dbPort: pluginData.dbPort || "3390"
    readonly property string dbName: pluginData.dbName || "Bluetti_AC200MAX"
    readonly property string dbUser: pluginData.dbUser || "root"
    readonly property string dbPassword: pluginData.dbPassword !== undefined ? pluginData.dbPassword : "kilroy"

    // ── State ─────────────────────────────────────────────────────────────────
    property var reading: null
    property bool loading: true
    property string errorText: ""
    property double ageSecs: 0
    /// [unixSeconds, batteryPercent] pairs for the last 24 hours.
    property var history: []

    readonly property bool hasData: reading !== null
    readonly property bool stale: hasData && ageSecs > staleSecs
    readonly property bool ok: hasData && !stale

    readonly property int battery: hasData ? Math.round(reading.battery || 0) : 0
    // Net flow is everything coming in minus everything going out; the net_power
    // column only accounts for the DC side, so it is recomputed here.
    readonly property int netPower: hasData
        ? Math.round((Number(reading.dcIn) || 0) + (Number(reading.acIn) || 0)
                     - (Number(reading.acOut) || 0) - (Number(reading.dcOut) || 0))
        : 0
    readonly property int chargingState: hasData ? (reading.chargingState || 0) : 0
    readonly property bool charging: ok && chargingState > 0

    // ── Time-to-full estimate ───────────────────────────────────────────────
    // The AC200MAX has a 2048 Wh battery; charging losses are roughly 20 %
    // (AC/solar in is measured upstream of the cells), so the energy actually
    // landing in the pack is ~80 % of the net input power.
    readonly property double batteryCapacityWh: pluginData.batteryCapacityWh !== undefined ? pluginData.batteryCapacityWh : 2048
    readonly property double chargeEfficiency: pluginData.chargeEfficiency !== undefined ? pluginData.chargeEfficiency : 0.8

    readonly property double hoursToFull: {
        if (!charging || netPower <= 0 || battery >= 100)
            return NaN
        const energyNeeded = (100 - battery) / 100 * batteryCapacityWh
        return energyNeeded / (netPower * chargeEfficiency)
    }

    popoutWidth: 420

    // ── Data access ───────────────────────────────────────────────────────────
    // MariaDB is queried directly with the mariadb client; the newest row of the
    // readings table is returned as a single JSON document.
    readonly property string sql: "SELECT JSON_OBJECT("
        + "'ts', DATE_FORMAT(timestamp, '%Y-%m-%d %H:%i:%s'),"
        + "'battery', total_battery_percent,"
        + "'voltage', total_battery_voltage,"
        + "'acIn', ac_input_power,"
        + "'dcIn', dc_input_power,"
        + "'acOut', ac_output_power,"
        + "'dcOut', dc_output_power,"
        + "'netPower', net_power,"
        + "'chargingState', charging_state,"
        + "'powerRate', power_rate,"
        + "'acOn', ac_output_on,"
        + "'dcOn', dc_output_on,"
        + "'acVolt', internal_ac_voltage,"
        + "'acCurrent', internal_current_one,"
        + "'acFreq', internal_ac_frequency,"
        + "'dcVolt', internal_dc_input_voltage,"
        + "'dcCurrent', internal_dc_input_current,"
        + "'packVoltage', pack_voltage,"
        + "'packPercent', pack_battery_percent,"
        + "'generation', power_generation"
        + ") FROM readings ORDER BY timestamp DESC LIMIT 1;"

    // Battery percentage over the last 24 h, averaged into 10 minute buckets.
    // The window is anchored on the newest row rather than NOW() because the
    // MariaDB container runs on UTC while the collector writes host-local times.
    readonly property string historySql: "SELECT COALESCE(JSON_ARRAYAGG(JSON_ARRAY(t, p)), '[]') FROM ("
        + "SELECT MIN(UNIX_TIMESTAMP(timestamp)) AS t, ROUND(AVG(total_battery_percent)) AS p"
        + " FROM readings"
        + " WHERE timestamp >= (SELECT MAX(timestamp) FROM readings) - INTERVAL 24 HOUR"
        + " AND total_battery_percent IS NOT NULL"
        + " GROUP BY FLOOR(UNIX_TIMESTAMP(timestamp) / 600)"
        + " ORDER BY t) q;"

    function shq(value) {
        return "'" + String(value).replace(/'/g, "'\\''") + "'"
    }

    function buildCommand(statement) {
        return "MYSQL_PWD=" + shq(dbPassword)
            + " mariadb -h" + shq(dbHost)
            + " -P" + shq(dbPort)
            + " -u" + shq(dbUser)
            + " -D" + shq(dbName)
            + " --batch --skip-column-names --raw --connect-timeout=4"
            + " -e " + shq(statement)
    }

    // The collector writes host-local timestamps while the MariaDB container runs
    // on UTC, so the age is computed here rather than with TIMESTAMPDIFF.
    function parseTimestamp(ts) {
        const m = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})$/.exec(String(ts).trim())
        if (!m)
            return NaN
        return new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]).getTime()
    }

    function refreshAge() {
        if (!reading || !reading.ts) {
            ageSecs = 0
            return
        }
        const t = parseTimestamp(reading.ts)
        ageSecs = isNaN(t) ? 0 : Math.max(0, (Date.now() - t) / 1000)
    }

    function fetchReading() {
        Proc.runCommand("bluettiMonitor.query", ["sh", "-c", buildCommand(sql)], (stdout, exitCode) => {
            root.loading = false
            const out = (stdout || "").trim()
            if (exitCode !== 0) {
                root.errorText = "Database query failed (exit " + exitCode + ")"
                root.reading = null
                root.refreshAge()
                return
            }
            if (out.length === 0) {
                root.errorText = "No readings in the database yet"
                root.reading = null
                root.refreshAge()
                return
            }
            try {
                root.reading = JSON.parse(out)
                root.errorText = ""
            } catch (e) {
                root.errorText = "Unreadable response from the database"
                root.reading = null
            }
            root.refreshAge()
        }, 200, 8000)
    }

    function fetchHistory() {
        Proc.runCommand("bluettiMonitor.history", ["sh", "-c", buildCommand(historySql)], (stdout, exitCode) => {
            if (exitCode !== 0) {
                return
            }
            const out = (stdout || "").trim()
            if (out.length === 0) {
                root.history = []
                return
            }
            try {
                const parsed = JSON.parse(out)
                // JSON_ARRAYAGG does not promise ordering, so sort by timestamp.
                parsed.sort((a, b) => a[0] - b[0])
                root.history = parsed
            } catch (e) {
                root.history = []
            }
        }, 200, 10000)
    }

    Timer {
        interval: root.refreshSecs * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.fetchReading()
    }

    // The 24 h chart changes slowly; no need to redraw it on every poll.
    Timer {
        interval: 60000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.fetchHistory()
    }

    // Keeps the "updated Ns ago" label and the stale flag moving between polls.
    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: root.refreshAge()
    }

    // ── Formatting ────────────────────────────────────────────────────────────
    function num(value, digits) {
        if (value === undefined || value === null)
            return "—"
        const n = Number(value)
        return isNaN(n) ? "—" : n.toFixed(digits === undefined ? 0 : digits)
    }

    function watts(value) {
        return value === undefined || value === null ? "—" : Math.round(Number(value)) + " W"
    }

    function signedWatts(value) {
        const n = Math.round(Number(value) || 0)
        return (n >= 0 ? "+" : "") + n + " W"
    }

    function ageLabel() {
        if (!hasData)
            return "no data"
        const s = Math.round(ageSecs)
        if (s < 60)
            return s + "s ago"
        if (s < 3600)
            return Math.floor(s / 60) + "m ago"
        if (s < 86400)
            return Math.floor(s / 3600) + "h ago"
        return Math.floor(s / 86400) + "d ago"
    }

    function chargingLabel() {
        switch (chargingState) {
        case 1:
            return "Charging from solar"
        case 2:
            return "Charging from AC"
        case 3:
            return "Charging from solar + AC"
        default:
            return "Not charging"
        }
    }

    // "2 h 15 m" style duration; under a minute shows "< 1 m".
    function durationLabel(hours) {
        if (isNaN(hours))
            return ""
        if (hours < 1 / 60)
            return "< 1 m"
        const totalMinutes = Math.round(hours * 60)
        if (totalMinutes < 60)
            return totalMinutes + " m"
        const h = Math.floor(totalMinutes / 60)
        const m = totalMinutes % 60
        return m > 0 ? h + " h " + m + " m" : h + " h"
    }

    // Wall-clock time when the battery should reach 100 %, e.g. "13:07".
    // Anchored on the reading's timestamp, not now, so a stale row does not
    // shift the estimate.
    function etaClockLabel() {
        if (isNaN(hoursToFull))
            return "—"
        const baseMs = Date.now() - ageSecs * 1000
        return new Date(baseMs + hoursToFull * 3600 * 1000).toLocaleTimeString(Qt.locale(), "HH:mm")
    }

    function batteryIcon() {
        if (!ok)
            return "battery_unknown"
        if (charging)
            return "battery_charging_full"
        if (battery >= 90)
            return "battery_full"
        if (battery >= 60)
            return "battery_5_bar"
        if (battery >= 40)
            return "battery_3_bar"
        if (battery >= 20)
            return "battery_2_bar"
        return "battery_alert"
    }

    function statusColor() {
        if (!ok)
            return Theme.surfaceVariantText
        if (battery <= 20 && !charging)
            return Theme.error
        if (charging)
            return Theme.secondary
        return Theme.primary
    }

    // Charging is green, discharging is red.
    function netColor() {
        if (!ok)
            return Theme.surfaceVariantText
        return netPower >= 0 ? Theme.success : Theme.error
    }

    function barText() {
        if (loading && !hasData)
            return "…"
        if (!hasData)
            return "—"
        return battery + "%"
    }

    readonly property bool showNetInBar: showPowerInBar && ok

    // ── Bar pills ─────────────────────────────────────────────────────────────
    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            DankIcon {
                name: root.batteryIcon()
                color: root.statusColor()
                size: root.iconSize
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: root.barText()
                color: root.statusColor()
                font.pixelSize: Theme.fontSizeMedium
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.showNetInBar
                text: root.signedWatts(root.netPower)
                color: root.netColor()
                font.pixelSize: Theme.fontSizeMedium
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: 2
            anchors.horizontalCenter: parent.horizontalCenter

            DankIcon {
                name: root.batteryIcon()
                color: root.statusColor()
                size: root.iconSize
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.hasData ? root.battery + "%" : "—"
                color: root.statusColor()
                font.pixelSize: Theme.fontSizeSmall
            }

            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: root.showNetInBar
                text: (root.netPower >= 0 ? "+" : "") + root.netPower
                color: root.netColor()
                font.pixelSize: Theme.fontSizeSmall
            }
        }
    }

    // ── Popout ────────────────────────────────────────────────────────────────
    popoutContent: Component {
        Column {
            width: parent.width
            spacing: Theme.spacingM
            topPadding: Theme.spacingM
            bottomPadding: Theme.spacingM

            // Header
            Item {
                width: parent.width
                height: 68

                Rectangle {
                    anchors.fill: parent
                    radius: Theme.cornerRadius * 1.5
                    gradient: Gradient {
                        GradientStop {
                            position: 0.0
                            color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.15)
                        }
                        GradientStop {
                            position: 1.0
                            color: Qt.rgba(Theme.secondary.r, Theme.secondary.g, Theme.secondary.b, 0.08)
                        }
                    }
                    border.width: 1
                    border.color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.25)
                }

                Row {
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.spacingM
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.spacingM

                    Item {
                        width: 40
                        height: 40
                        anchors.verticalCenter: parent.verticalCenter

                        Rectangle {
                            anchors.fill: parent
                            radius: 20
                            color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.2)
                        }

                        DankIcon {
                            name: root.batteryIcon()
                            size: 22
                            color: root.statusColor()
                            anchors.centerIn: parent
                        }
                    }

                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2

                        StyledText {
                            text: root.hasData ? root.battery + "%  ·  " + root.num(root.reading.voltage, 2) + " V" : "Bluetti AC200MAX"
                            font.bold: true
                            font.pixelSize: Theme.fontSizeLarge
                            color: Theme.surfaceText
                        }

                        StyledText {
                            text: root.errorText.length > 0 ? root.errorText
                                : root.stale ? "Stale data — collector stopped?"
                                : root.chargingLabel()
                            font.pixelSize: Theme.fontSizeSmall
                            color: root.errorText.length > 0 || root.stale ? Theme.error : Theme.surfaceVariantText
                        }
                    }
                }

                Item {
                    width: 32
                    height: 32
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.spacingM
                    anchors.verticalCenter: parent.verticalCenter

                    Rectangle {
                        anchors.fill: parent
                        radius: 16
                        color: refreshArea.containsMouse ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.2) : "transparent"
                        Behavior on color {
                            ColorAnimation {
                                duration: 150
                            }
                        }
                    }

                    DankIcon {
                        name: "refresh"
                        size: 20
                        color: Theme.primary
                        anchors.centerIn: parent
                    }

                    MouseArea {
                        id: refreshArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.fetchReading()
                            root.fetchHistory()
                        }
                    }
                }
            }

            // ── 24 hour battery chart ────────────────────────────────────────
            StyledRect {
                width: parent.width
                height: 150
                radius: Theme.cornerRadius * 1.5
                color: Qt.rgba(Theme.surfaceContainer.r, Theme.surfaceContainer.g, Theme.surfaceContainer.b, 0.5)
                border.width: 1
                border.color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.1)
                clip: true

                Row {
                    anchors.top: parent.top
                    anchors.topMargin: Theme.spacingS
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.spacingM
                    spacing: Theme.spacingXS

                    DankIcon {
                        name: "show_chart"
                        size: 14
                        color: Theme.primary
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        text: "Battery · last 24 h"
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Bold
                        color: Theme.surfaceText
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                StyledText {
                    anchors.centerIn: parent
                    visible: !root.history || root.history.length < 2
                    text: "Not enough history yet"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }

                Canvas {
                    id: chart
                    anchors.fill: parent
                    anchors.topMargin: 26
                    anchors.bottomMargin: Theme.spacingS
                    anchors.leftMargin: Theme.spacingM
                    anchors.rightMargin: Theme.spacingM
                    visible: root.history && root.history.length >= 2
                    antialiasing: true

                    // Room on the left for the 0/50/100 labels.
                    readonly property int gutter: 26

                    Connections {
                        target: root
                        function onHistoryChanged() {
                            chart.requestPaint()
                        }
                    }

                    onPaint: {
                        const ctx = getContext("2d")
                        ctx.reset()

                        const points = root.history
                        if (!points || points.length < 2)
                            return

                        const left = gutter
                        const right = width
                        const top = 10
                        const bottom = height - 14
                        const plotWidth = right - left
                        const plotHeight = bottom - top
                        if (plotWidth <= 0 || plotHeight <= 0)
                            return

                        // Fixed 24 h window ending at the newest sample, so gaps
                        // in collection show as gaps rather than being stretched.
                        const tEnd = points[points.length - 1][0]
                        const tStart = tEnd - 24 * 3600
                        const span = Math.max(1, tEnd - tStart)

                        const xAt = t => left + ((t - tStart) / span) * plotWidth
                        const yAt = pct => bottom - (Math.max(0, Math.min(100, pct)) / 100) * plotHeight

                        // Horizontal guides at 0 / 25 / 50 / 75 / 100 %.
                        ctx.lineWidth = 1
                        ctx.font = "9px sans-serif"
                        ctx.textAlign = "right"
                        ctx.textBaseline = "middle"
                        for (const pct of [0, 25, 50, 75, 100]) {
                            const y = yAt(pct)
                            ctx.strokeStyle = Qt.rgba(Theme.surfaceVariantText.r, Theme.surfaceVariantText.g,
                                                      Theme.surfaceVariantText.b, pct === 0 || pct === 100 ? 0.25 : 0.12)
                            ctx.beginPath()
                            ctx.moveTo(left, y)
                            ctx.lineTo(right, y)
                            ctx.stroke()

                            if (pct % 50 === 0) {
                                ctx.fillStyle = Qt.rgba(Theme.surfaceVariantText.r, Theme.surfaceVariantText.g,
                                                        Theme.surfaceVariantText.b, 0.8)
                                ctx.fillText(pct + "%", left - 4, y)
                            }
                        }

                        // Filled area under the curve.
                        const gradient = ctx.createLinearGradient(0, top, 0, bottom)
                        gradient.addColorStop(0, Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.35))
                        gradient.addColorStop(1, Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.02))

                        ctx.beginPath()
                        ctx.moveTo(xAt(points[0][0]), bottom)
                        for (const point of points)
                            ctx.lineTo(xAt(point[0]), yAt(point[1]))
                        ctx.lineTo(xAt(points[points.length - 1][0]), bottom)
                        ctx.closePath()
                        ctx.fillStyle = gradient
                        ctx.fill()

                        // The curve itself.
                        ctx.beginPath()
                        ctx.moveTo(xAt(points[0][0]), yAt(points[0][1]))
                        for (const point of points)
                            ctx.lineTo(xAt(point[0]), yAt(point[1]))
                        ctx.strokeStyle = Theme.primary
                        ctx.lineWidth = 2
                        ctx.lineJoin = "round"
                        ctx.stroke()

                        // Marker on the newest sample.
                        const lastX = xAt(points[points.length - 1][0])
                        const lastY = yAt(points[points.length - 1][1])
                        ctx.beginPath()
                        ctx.arc(lastX, lastY, 3, 0, 2 * Math.PI)
                        ctx.fillStyle = Theme.primary
                        ctx.fill()

                        // Time axis ends.
                        ctx.fillStyle = Qt.rgba(Theme.surfaceVariantText.r, Theme.surfaceVariantText.g,
                                                Theme.surfaceVariantText.b, 0.8)
                        ctx.textBaseline = "top"
                        ctx.textAlign = "left"
                        ctx.fillText("-24 h", left, bottom + 3)
                        ctx.textAlign = "right"
                        ctx.fillText("now", right, bottom + 3)
                    }
                }
            }

            // ── Time-to-full estimate ────────────────────────────────────
            StyledRect {
                width: parent.width
                height: 34
                radius: Theme.cornerRadius * 1.5
                color: Qt.rgba(Theme.surfaceContainer.r, Theme.surfaceContainer.g, Theme.surfaceContainer.b, 0.5)
                border.width: 1
                border.color: Qt.rgba(Theme.secondary.r, Theme.secondary.g, Theme.secondary.b, 0.15)
                visible: !isNaN(root.hoursToFull)

                DankIcon {
                    name: "schedule"
                    size: 16
                    color: Theme.secondary
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.spacingM
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    text: "Full in " + root.durationLabel(root.hoursToFull)
                        + "  ·  at " + root.etaClockLabel()
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.spacingM + 16 + Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            // Power summary
            StyledRect {
                width: parent.width
                height: powerGrid.implicitHeight + Theme.spacingM * 2
                radius: Theme.cornerRadius * 1.5
                color: Qt.rgba(Theme.surfaceContainer.r, Theme.surfaceContainer.g, Theme.surfaceContainer.b, 0.5)
                border.width: 1
                border.color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.1)

                Grid {
                    id: powerGrid
                    anchors.centerIn: parent
                    width: parent.width - Theme.spacingM * 2
                    columns: 2
                    columnSpacing: Theme.spacingM
                    rowSpacing: Theme.spacingS

                    Repeater {
                        model: root.hasData ? [
                            { label: "Solar in", value: root.watts(root.reading.dcIn), icon: "solar_power" },
                            { label: "AC in", value: root.watts(root.reading.acIn), icon: "power" },
                            { label: "AC out", value: root.watts(root.reading.acOut), icon: "bolt" },
                            { label: "DC out", value: root.watts(root.reading.dcOut), icon: "usb" },
                            { label: "Net", value: root.signedWatts(root.netPower), icon: "trending_up", valueColor: root.netColor() },
                            { label: "Generated", value: root.num(root.reading.generation, 1) + " kWh", icon: "insights" }
                        ] : []

                        delegate: Row {
                            width: (powerGrid.width - Theme.spacingM) / 2
                            spacing: Theme.spacingS

                            DankIcon {
                                name: modelData.icon
                                size: 16
                                color: Theme.primary
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            StyledText {
                                text: modelData.label
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            StyledText {
                                text: modelData.value
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Bold
                                color: modelData.valueColor !== undefined ? modelData.valueColor : Theme.surfaceText
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                    }

                    StyledText {
                        visible: !root.hasData
                        text: root.loading ? "Querying the database…" : "No reading available"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }
                }
            }

            // Detail rows
            StyledRect {
                width: parent.width
                visible: root.hasData
                height: detailColumn.implicitHeight + Theme.spacingM * 2
                radius: Theme.cornerRadius * 1.5
                color: Qt.rgba(Theme.surfaceContainer.r, Theme.surfaceContainer.g, Theme.surfaceContainer.b, 0.5)
                border.width: 1
                border.color: Qt.rgba(Theme.secondary.r, Theme.secondary.g, Theme.secondary.b, 0.1)

                Column {
                    id: detailColumn
                    anchors.centerIn: parent
                    width: parent.width - Theme.spacingM * 2
                    spacing: Theme.spacingXS

                    Repeater {
                        model: root.hasData ? [
                            { label: "AC output", value: (root.reading.acOn ? "ON" : "OFF") + "  ·  " + root.num(root.reading.acVolt, 0) + " V  ·  " + root.num(root.reading.acFreq, 0) + " Hz" },
                            { label: "DC output", value: (root.reading.dcOn ? "ON" : "OFF") + "  ·  " + root.watts(root.reading.dcOut) },
                            { label: "Solar input", value: root.num(root.reading.dcVolt, 0) + " V  ·  " + root.num(root.reading.dcCurrent, 2) + " A" },
                            { label: "Pack", value: root.num(root.reading.packPercent, 0) + "%  ·  " + root.num(root.reading.packVoltage, 2) + " V" }
                        ] : []

                        delegate: Item {
                            width: detailColumn.width
                            height: 22

                            StyledText {
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.label
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }

                            StyledText {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.value
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceText
                            }
                        }
                    }
                }
            }

            // Footer
            Item {
                width: parent.width
                height: 20

                StyledText {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.hasData ? "Updated " + root.ageLabel() : "—"
                    font.pixelSize: Theme.fontSizeSmall
                    color: root.stale ? Theme.error : Theme.surfaceVariantText
                }

                StyledText {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: "every " + root.refreshSecs + "s"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }
            }
        }
    }
}
