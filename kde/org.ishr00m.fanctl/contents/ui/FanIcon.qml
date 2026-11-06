import QtQuick
import org.kde.kirigami as Kirigami

// Значок вентилятора: крутится тем быстрее, чем выше ступень; на 0 стоит.
Item {
    id: fan
    property int level: 0
    property color color: Kirigami.Theme.textColor
    property bool spin: true

    Canvas {
        id: blades
        anchors.centerIn: parent
        width: Math.min(fan.width, fan.height)
        height: width
        onPaint: {
            const ctx = getContext("2d");
            const r = width / 2;
            ctx.reset();
            ctx.translate(r, r);
            ctx.fillStyle = fan.color;
            ctx.strokeStyle = fan.color;
            ctx.lineWidth = Math.max(1, r * 0.09);
            ctx.beginPath();
            ctx.arc(0, 0, r * 0.92, 0, 2 * Math.PI);
            ctx.globalAlpha = 0.35;
            ctx.stroke();
            ctx.globalAlpha = 1;
            for (let i = 0; i < 3; i++) {
                ctx.save();
                ctx.rotate(i * 2 * Math.PI / 3);
                ctx.beginPath();
                ctx.moveTo(0, 0);
                ctx.bezierCurveTo(r * 0.15, -r * 0.35, r * 0.62, -r * 0.62, r * 0.25, -r * 0.82);
                ctx.bezierCurveTo(-r * 0.12, -r * 0.62, -r * 0.18, -r * 0.3, 0, 0);
                ctx.fill();
                ctx.restore();
            }
            ctx.beginPath();
            ctx.arc(0, 0, r * 0.14, 0, 2 * Math.PI);
            ctx.fill();
        }
        Connections {
            target: fan
            function onColorChanged() { blades.requestPaint(); }
        }
        onWidthChanged: requestPaint()

        RotationAnimation on rotation {
            running: fan.spin && fan.level > 0
            loops: Animation.Infinite
            from: 0; to: 360
            duration: [0, 2400, 1200, 600][Math.max(0, Math.min(3, fan.level))] || 2400
        }
    }
}
