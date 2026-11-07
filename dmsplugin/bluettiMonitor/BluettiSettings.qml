import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root

    pluginId: "bluettiMonitor"

    StyledText {
        width: parent.width
        text: "Bluetti Monitor"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Reads the newest row from the Bluetti readings table in MariaDB. The bluetti_reader.py collector must be running for the values to stay fresh."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    SliderSetting {
        settingKey: "refreshSecs"
        label: "Refresh Interval"
        description: "How often the database is polled for a new reading."
        defaultValue: 10
        minimum: 5
        maximum: 120
        unit: "s"
        leftIcon: "schedule"
    }

    SliderSetting {
        settingKey: "staleSecs"
        label: "Stale Threshold"
        description: "A reading older than this is shown as stale, which usually means the collector has stopped."
        defaultValue: 180
        minimum: 30
        maximum: 900
        unit: "s"
        leftIcon: "running_with_errors"
    }

    ToggleSetting {
        settingKey: "showPowerInBar"
        label: "Show Power In Bar"
        description: "Append the net charge or discharge wattage next to the battery percentage."
        defaultValue: true
    }

    StringSetting {
        settingKey: "dbHost"
        label: "Database Host"
        description: "Hostname or IP of the MariaDB server holding the readings table."
        defaultValue: "127.0.0.1"
        placeholder: "127.0.0.1"
    }

    StringSetting {
        settingKey: "dbPort"
        label: "Database Port"
        description: "TCP port of the MariaDB server."
        defaultValue: "3390"
        placeholder: "3390"
    }

    StringSetting {
        settingKey: "dbName"
        label: "Database Name"
        description: "Schema containing the readings table."
        defaultValue: "Bluetti_AC200MAX"
        placeholder: "Bluetti_AC200MAX"
    }

    StringSetting {
        settingKey: "dbUser"
        label: "Database User"
        description: "MariaDB user with read access to the readings table."
        defaultValue: "root"
        placeholder: "root"
    }

    StringSetting {
        settingKey: "dbPassword"
        label: "Database Password"
        description: "Passed to the client through the MYSQL_PWD environment variable, never on the command line."
        defaultValue: "kilroy"
        placeholder: "kilroy"
    }
}
