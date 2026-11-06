import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    readonly property string api: "http://127.0.0.1:8766"
    property var st: null          // /state response
    property bool online: false
    property var editTh: null      // thresholds being edited (before sending)

    // UI language follows the system locale: Russian for ru_*, English otherwise
    readonly property bool ru: Qt.locale().name.startsWith("ru")
    function tx(en, ruText) { return ru ? ruText : en; }
    function reasonText(code) {
        const m = { gpu: tx("GPU", "видеокарта"), cpu: tx("CPU", "процессор"), nvme: tx("SSD", "SSD"),
                    gpu_fan: tx("GPU fan spinning", "кулер видеокарты"), cool: tx("everything is cool", "всё холодное"),
                    cooling: tx("cooling down, will lower soon", "остываю, скоро снижу"),
                    manual: tx("manual mode", "ручной режим"), nodata: tx("no sensor data — max", "нет данных датчиков — максимум") };
        return m[code] || code;
    }

    readonly property int level: st && st.level !== null ? st.level : (st ? st.target : 0)
    readonly property bool manual: st && st.cfg.mode === "manual"
    readonly property bool espDown: online && st !== null && !st.esp
    readonly property string espLostText: espDown
        ? tx("No connection to ESP32", "Нет связи с ESP32")
          + (st.esp_lost_at ? tx(" since ", " с ") + Qt.formatTime(new Date(st.esp_lost_at * 1000), "hh:mm") : "")
          + tx(" — fans are not being controlled", " — вентиляторами сейчас не управляю")
        : ""
    readonly property var levelColors: [Kirigami.Theme.disabledTextColor, Kirigami.Theme.positiveTextColor,
                                        Kirigami.Theme.neutralTextColor, Kirigami.Theme.negativeTextColor]
    readonly property var levelNames: [tx("stopped", "стоят"), tx("quiet", "тихо"), tx("medium", "средне"), tx("max", "максимум")]
    readonly property var presetNames: ({ quiet: tx("Quiet", "Тихий"), balance: tx("Balance", "Баланс"),
                                          cool: tx("Cool", "Холодный"), custom: tx("Custom", "Свой") })
    readonly property var sensors: [["gpu", tx("GPU", "Видеокарта")], ["cpu", tx("CPU", "Процессор")], ["nvme", "SSD"]]

    function request(method, path, body, onDone) {
        const xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            if (xhr.status === 200) {
                try { onDone(JSON.parse(xhr.responseText)); root.online = true; return; } catch (e) {}
            }
            root.online = false;
        };
        xhr.open(method, root.api + path);
        if (body) xhr.setRequestHeader("Content-Type", "application/json");
        xhr.send(body ? JSON.stringify(body) : null);
    }
    function refresh() {
        request("GET", "/state", null, s => {
            root.st = s;
            if (!thSend.running) root.editTh = JSON.parse(JSON.stringify(s.cfg.thresholds));
        });
    }
    function setCfg(obj) { request("POST", "/config", obj, s => root.st = s); }
    property string pressMsg: ""
    function press(name) {
        const xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            root.pressMsg = xhr.status === 200 ? tx("✓ sent", "✓ отправлено")
                : xhr.status === 503 ? tx("✗ no ESP32", "✗ нет связи с ESP32") : tx("✗ service error", "✗ служба не ответила");
            pressMsgTimer.restart();
        };
        xhr.open("POST", root.api + "/press");
        xhr.setRequestHeader("Content-Type", "application/json");
        xhr.send(JSON.stringify({ name: name }));
    }
    Timer { id: pressMsgTimer; interval: 2000; onTriggered: root.pressMsg = "" }
    function deg(v) { return v === null || v === undefined ? "—" : Math.round(v) + "°"; }
    function dur(sec) {
        const h = Math.floor(sec / 3600), m = Math.floor(sec % 3600 / 60);
        return h ? h + tx(" h ", " ч ") + m + tx(" min", " мин") : m + tx(" min", " мин");
    }
    // temperature colour relative to the sensor's thresholds
    function tempColor(key) {
        if (!st || st.temps[key] === null) return Kirigami.Theme.textColor;
        const t = st.temps[key], th = st.cfg.thresholds[key];
        if (t >= th[2]) return Kirigami.Theme.negativeTextColor;
        if (t >= th[1]) return Kirigami.Theme.neutralTextColor;
        return Kirigami.Theme.textColor;
    }

    Timer {
        interval: root.expanded ? 2000 : 5000
        running: true; repeat: true; triggeredOnStart: true
        onTriggered: root.refresh()
    }
    Timer {
        id: thSend
        interval: 900
        onTriggered: root.setCfg({ thresholds: root.editTh })
    }

    Plasmoid.icon: "temperature-normal"
    toolTipMainText: espDown ? espLostText : tx("Case fans: ", "Вентиляторы: ")
        + (online && st ? tx("speed ", "ступень ") + level + " (" + levelNames[level] + ")" : tx("service unavailable", "служба недоступна"))
    toolTipSubText: online && st
        ? tx("GPU ", "Видеокарта ") + deg(st.temps.gpu) + tx(" · CPU ", " · процессор ") + deg(st.temps.cpu) + " · SSD " + deg(st.temps.nvme)
          + "\n" + (manual ? tx("Manual mode", "Ручной режим")
                           : tx("Auto, ", "Авто, ") + presetNames[st.cfg.preset].toLowerCase() + ": " + reasonText(st.reason))
        : tx("Start it: systemctl --user start fanctl", "Запусти: systemctl --user start fanctl")

    compactRepresentation: MouseArea {
        readonly property bool vertical: Plasmoid.formFactor === PlasmaCore.Types.Vertical
        Layout.minimumWidth: vertical ? -1 : row.implicitWidth
        Layout.minimumHeight: vertical ? row.implicitHeight : -1
        hoverEnabled: true
        onClicked: root.expanded = !root.expanded

        RowLayout {
            id: row
            anchors.fill: parent
            spacing: Kirigami.Units.smallSpacing
            FanIcon {
                Layout.fillHeight: true
                Layout.preferredWidth: height
                level: root.online && !root.espDown ? root.level : 0
                color: !root.online ? Kirigami.Theme.disabledTextColor
                       : root.espDown ? Kirigami.Theme.negativeTextColor
                       : root.manual ? Kirigami.Theme.highlightColor : Kirigami.Theme.textColor
            }
            PlasmaComponents.Label {
                visible: !parent.parent.vertical
                text: root.espDown ? "!" : root.online && root.st ? String(root.level) : "×"
                color: root.espDown ? Kirigami.Theme.negativeTextColor
                       : root.online ? root.levelColors[root.level] : Kirigami.Theme.disabledTextColor
                font.bold: true
                Layout.fillHeight: true
                Layout.rightMargin: Kirigami.Units.smallSpacing
                verticalAlignment: Text.AlignVCenter
                fontSizeMode: Text.VerticalFit
                font.pixelSize: height * 0.6
                minimumPixelSize: 8
            }
        }
    }

    fullRepresentation: PlasmaExtras.Representation {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 30
        Layout.preferredWidth: Kirigami.Units.gridUnit * 30
        Layout.minimumHeight: Kirigami.Units.gridUnit * 38
        Layout.preferredHeight: Kirigami.Units.gridUnit * 38
        collapseMarginsHint: true

        header: PlasmaExtras.PlasmoidHeading {
            RowLayout {
                anchors.fill: parent
                Kirigami.Heading { level: 3; text: root.tx("Case fans", "Вентиляторы корпуса"); Layout.fillWidth: true }
                Rectangle {
                    width: Kirigami.Units.smallSpacing * 2; height: width; radius: width / 2
                    color: root.online && root.st && root.st.esp ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.negativeTextColor
                    PlasmaCore.ToolTipArea {
                        anchors.fill: parent
                        mainText: !root.online ? root.tx("fanctl service is not responding", "Служба fanctl не отвечает")
                                  : root.st.esp ? root.tx("ESP32 connected", "ESP32 на связи") : root.tx("ESP32 not responding", "ESP32 не отвечает")
                    }
                }
            }
        }

        ColumnLayout {
            id: body
            anchors.fill: parent
            anchors.margins: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.largeSpacing

            PlasmaComponents.Label {
                visible: !root.online
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: root.tx("Service is not responding. Check: systemctl --user status fanctl", "Служба не отвечает. Проверь: systemctl --user status fanctl")
            }

            Kirigami.InlineMessage {
                Layout.fillWidth: true
                visible: root.espDown
                type: Kirigami.MessageType.Error
                text: root.espLostText + root.tx(". Check the board's power/USB; the service reconnects by itself.", ". Проверь питание и USB-кабель платы; служба переподключится сама.")
            }

            // ── current state ──
            RowLayout {
                visible: root.online && root.st !== null
                spacing: Kirigami.Units.largeSpacing
                FanIcon {
                    Layout.preferredWidth: Kirigami.Units.iconSizes.huge
                    Layout.preferredHeight: Kirigami.Units.iconSizes.huge
                    level: root.level
                    color: root.levelColors[root.level]
                }
                ColumnLayout {
                    spacing: 0
                    Kirigami.Heading { level: 1; text: root.tx("Speed ", "Ступень ") + root.level }
                    PlasmaComponents.Label {
                        text: root.st ? (root.st.level === null ? root.tx("setting…", "выставляю…") : root.levelNames[root.level]) : ""
                    }
                    PlasmaComponents.Label {
                        opacity: 0.7
                        font: Kirigami.Theme.smallFont
                        text: root.st ? (root.manual ? root.reasonText("manual") : root.tx("reason: ", "причина: ") + root.reasonText(root.st.reason)) : ""
                    }
                }
                Item { Layout.fillWidth: true }
                GridLayout {
                    columns: 2
                    columnSpacing: Kirigami.Units.smallSpacing
                    rowSpacing: 0
                    Repeater {
                        model: root.sensors
                        delegate: PlasmaComponents.Label {
                            Layout.row: index; Layout.column: 0
                            text: modelData[1] + ":"; opacity: 0.7
                        }
                    }
                    Repeater {
                        model: root.sensors
                        delegate: PlasmaComponents.Label {
                            Layout.row: index; Layout.column: 1
                            Layout.alignment: Qt.AlignRight
                            font.bold: true
                            text: root.st ? root.deg(root.st.temps[modelData[0]]) : ""
                            color: root.tempColor(modelData[0])
                        }
                    }
                    PlasmaComponents.Label { Layout.row: 3; Layout.column: 0; text: root.tx("GPU fan:", "Кулер видеокарты:"); opacity: 0.7 }
                    PlasmaComponents.Label {
                        Layout.row: 3; Layout.column: 1; Layout.alignment: Qt.AlignRight
                        text: root.st && root.st.temps.gpu_fan !== null ? Math.round(root.st.temps.gpu_fan) + "%" : "—"
                    }
                }
            }

            // ── mode ──
            RowLayout {
                visible: root.online && root.st !== null
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                PlasmaComponents.Label { text: root.tx("Mode:", "Режим:"); opacity: 0.7 }
                PlasmaComponents.Button {
                    text: root.tx("Auto", "Авто")
                    checkable: true
                    checked: !root.manual
                    onClicked: root.setCfg({ mode: "auto" })
                }
                Repeater {
                    model: 4
                    delegate: PlasmaComponents.Button {
                        text: String(index)
                        checkable: true
                        checked: root.manual && root.st.cfg.manual_level === index
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 2
                        onClicked: root.setCfg({ mode: "manual", manual_level: index })
                        PlasmaComponents.ToolTip { text: root.tx("Manual: speed ", "Вручную: ступень ") + index + " (" + root.levelNames[index] + ")" }
                    }
                }
            }

            // ── lighting ──
            RowLayout {
                visible: root.online && root.st !== null
                spacing: Kirigami.Units.smallSpacing
                PlasmaComponents.Label { text: root.tx("Lights:", "Подсветка:"); opacity: 0.7 }
                PlasmaComponents.Button {
                    text: root.tx("◀ mode", "◀ режим")
                    onClicked: root.press("mode -")
                    PlasmaComponents.ToolTip { text: root.tx("Previous lighting mode", "Предыдущий режим подсветки") }
                }
                PlasmaComponents.Button {
                    text: root.tx("mode ▶", "режим ▶")
                    onClicked: root.press("mode +")
                    PlasmaComponents.ToolTip { text: root.tx("Next lighting mode", "Следующий режим подсветки") }
                }
                Item { Layout.preferredWidth: Kirigami.Units.smallSpacing }
                Repeater {
                    model: [["R", "#e53935", root.tx("Red", "Красный")], ["G", "#43a047", root.tx("Green", "Зелёный")],
                            ["B", "#1e88e5", root.tx("Blue", "Синий")], ["white", "#f5f5f5", root.tx("White", "Белый")]]
                    delegate: Rectangle {
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 1.4
                        Layout.preferredHeight: Kirigami.Units.gridUnit * 1.4
                        radius: width / 2
                        color: modelData[1]
                        border.width: dot.containsMouse ? 2 : 1
                        border.color: dot.containsMouse ? Kirigami.Theme.highlightColor : Qt.rgba(0.5, 0.5, 0.5, 0.6)
                        scale: dot.pressed ? 0.85 : 1
                        MouseArea {
                            id: dot
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.press(modelData[0])
                        }
                        PlasmaCore.ToolTipArea { anchors.fill: parent; mainText: modelData[2] }
                    }
                }
                PlasmaComponents.Label {
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 7
                    text: root.pressMsg
                    font: Kirigami.Theme.smallFont
                    color: root.pressMsg.startsWith("✓") ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.negativeTextColor
                    elide: Text.ElideRight
                }
            }

            Kirigami.Separator { Layout.fillWidth: true; visible: root.online }

            // ── preset & thresholds ──
            RowLayout {
                visible: root.online && root.st !== null
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                PlasmaComponents.Label { text: root.tx("Preset:", "Пресет:"); opacity: 0.7 }
                Repeater {
                    model: ["quiet", "balance", "cool"]
                    delegate: PlasmaComponents.Button {
                        text: root.presetNames[modelData]
                        checkable: true
                        checked: root.st && root.st.cfg.preset === modelData
                        onClicked: { thSend.stop(); root.setCfg({ preset: modelData }); }
                    }
                }
                PlasmaComponents.Label {
                    visible: root.st && root.st.cfg.preset === "custom"
                    text: root.tx("custom", "свой")
                    font.italic: true
                }
            }

            GridLayout {
                visible: root.online && root.editTh !== null
                columns: 4
                columnSpacing: Kirigami.Units.largeSpacing
                rowSpacing: Kirigami.Units.smallSpacing
                PlasmaComponents.Label { text: root.tx("Threshold, °C", "Порог, °C"); opacity: 0.7 }
                Repeater {
                    model: 3
                    delegate: PlasmaComponents.Label {
                        text: "→ " + (index + 1)
                        color: root.levelColors[index + 1]
                        font.bold: true
                        Layout.alignment: Qt.AlignHCenter
                    }
                }
                Repeater {
                    model: root.sensors.length * 4
                    delegate: Loader {
                        readonly property int r: Math.floor(index / 4)
                        readonly property int c: index % 4
                        readonly property string key: root.sensors[r][0]
                        sourceComponent: c === 0 ? nameCell : spinCell
                        Component {
                            id: nameCell
                            PlasmaComponents.Label { text: root.sensors[r][1] }
                        }
                        Component {
                            id: spinCell
                            PlasmaComponents.SpinBox {
                                from: 30; to: 100
                                value: root.editTh ? root.editTh[key][c - 1] : 0
                                Layout.preferredWidth: Kirigami.Units.gridUnit * 4.5
                                onValueModified: {
                                    const th = JSON.parse(JSON.stringify(root.editTh));
                                    th[key][c - 1] = value;
                                    th[key].sort((a, b) => a - b);
                                    root.editTh = th;
                                    thSend.restart();
                                }
                            }
                        }
                    }
                }
            }

            PlasmaComponents.CheckBox {
                visible: root.online && root.st !== null
                text: root.tx("GPU fan spinning (≥50°) → at least speed 1", "Кулер видеокарты крутится (≥50°) → не ниже 1")
                checked: root.st ? root.st.cfg.gpu_fan_rule : true
                onToggled: root.setCfg({ gpu_fan_rule: checked })
            }

            Kirigami.Separator { Layout.fillWidth: true; visible: root.online }

            // ── today's stats ──
            ColumnLayout {
                visible: root.online && root.st !== null
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                readonly property var ti: root.st ? root.st.time_in : [0, 0, 0, 0]
                readonly property real total: Math.max(1, ti[0] + ti[1] + ti[2] + ti[3])
                RowLayout {
                    Layout.fillWidth: true
                    PlasmaComponents.Label { text: root.tx("Today", "Сегодня"); font.bold: true; Layout.fillWidth: true }
                    PlasmaComponents.Label {
                        opacity: 0.7
                        font: Kirigami.Theme.smallFont
                        text: root.st ? root.tx("changes: ", "переключений: ") + root.st.changes_today : ""
                    }
                }
                Row {
                    id: bar
                    Layout.fillWidth: true
                    height: Kirigami.Units.smallSpacing * 3
                    Repeater {
                        model: 4
                        delegate: Rectangle {
                            height: bar.height
                            width: bar.width * parent.parent.ti[index] / parent.parent.total
                            color: root.levelColors[index]
                            opacity: index === 0 ? 0.5 : 0.85
                        }
                    }
                }
                GridLayout {
                    Layout.fillWidth: true
                    columns: 2
                    Repeater {
                        model: 4
                        delegate: PlasmaComponents.Label {
                            Layout.fillWidth: true
                            font: Kirigami.Theme.smallFont
                            color: root.levelColors[index]
                            text: index + " — " + root.levelNames[index] + ": " + root.dur(parent.parent.ti[index])
                                  + " (" + Math.round(100 * parent.parent.ti[index] / parent.parent.total) + "%)"
                        }
                    }
                }
            }

            // ── last 30 minutes ──
            ColumnLayout {
                visible: root.online && root.st !== null && root.st.history.length > 1
                Layout.fillWidth: true
                spacing: 0
                RowLayout {
                    PlasmaComponents.Label { text: root.tx("Last 30 min", "30 минут"); font.bold: true; Layout.fillWidth: true }
                    PlasmaComponents.Label { text: root.tx("— GPU", "— видеокарта"); color: "#3daee9"; font: Kirigami.Theme.smallFont }
                    PlasmaComponents.Label { text: root.tx("— CPU", "— процессор"); color: "#f67400"; font: Kirigami.Theme.smallFont }
                    PlasmaComponents.Label { text: root.tx("▮ speed", "▮ ступень"); opacity: 0.6; font: Kirigami.Theme.smallFont }
                }
                Canvas {
                    id: chart
                    Layout.fillWidth: true
                    Layout.preferredHeight: Kirigami.Units.gridUnit * 5
                    property var hist: root.st ? root.st.history : []
                    onHistChanged: requestPaint()
                    onWidthChanged: requestPaint()
                    onPaint: {
                        const ctx = getContext("2d");
                        ctx.reset();
                        const h = hist;
                        if (!h || h.length < 2) return;
                        const t0 = h[0][0], t1 = h[h.length - 1][0], span = Math.max(1, t1 - t0);
                        const lo = 30, hi = 90;
                        const x = t => (t - t0) / span * width;
                        const y = v => height - (Math.min(hi, Math.max(lo, v)) - lo) / (hi - lo) * height;
                        // speeds as translucent bars
                        for (let i = 0; i < h.length - 1; i++) {
                            const lvl = h[i][1];
                            if (lvl === null || lvl === 0) continue;
                            ctx.fillStyle = root.levelColors[lvl];
                            ctx.globalAlpha = 0.18;
                            const bh = height * lvl / 3;
                            ctx.fillRect(x(h[i][0]), height - bh, x(h[i + 1][0]) - x(h[i][0]) + 0.5, bh);
                        }
                        ctx.globalAlpha = 1;
                        // 40/60/80 grid
                        ctx.strokeStyle = Kirigami.Theme.textColor;
                        ctx.globalAlpha = 0.12;
                        ctx.lineWidth = 1;
                        [40, 60, 80].forEach(v => { ctx.beginPath(); ctx.moveTo(0, y(v)); ctx.lineTo(width, y(v)); ctx.stroke(); });
                        ctx.globalAlpha = 1;
                        // temperature lines
                        [[2, "#3daee9"], [3, "#f67400"]].forEach(([col, color]) => {
                            ctx.strokeStyle = color;
                            ctx.lineWidth = 1.5;
                            ctx.beginPath();
                            let started = false;
                            h.forEach(p => {
                                if (p[col] === null) return;
                                if (!started) { ctx.moveTo(x(p[0]), y(p[col])); started = true; }
                                else ctx.lineTo(x(p[0]), y(p[col]));
                            });
                            ctx.stroke();
                        });
                        ctx.fillStyle = Kirigami.Theme.textColor;
                        ctx.globalAlpha = 0.5;
                        ctx.font = "9px sans-serif";
                        [40, 60, 80].forEach(v => ctx.fillText(v + "°", 2, y(v) - 2));
                    }
                }
            }
        }
    }
}
