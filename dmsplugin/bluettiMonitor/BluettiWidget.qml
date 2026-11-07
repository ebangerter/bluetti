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

    function shq(value) {
        return "'" + String(value).replace(/'/g, "'\\''") + "'"
    }

    function buildCommand() {
        return "MYSQL_PWD=" + shq(dbPassword)
            + " mariadb -h" + shq(dbHost)
            + " -P" + shq(dbPort)
            + " -u" + shq(dbUser)
            + " -D" + shq(dbName)
            + " --batch --skip-column-names --raw --connect-timeout=4"
            + " -e " + shq(sql)
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
        Proc.runCommand("bluettiMonitor.query", ["sh", "-c", buildCommand()], (stdout, exitCode) => {
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

    Timer {
        interval: root.refreshSecs * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.fetchReading()
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
                        onClicked: root.fetchReading()
                    }
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
