// Copyright (c) 2026 Private Internet Access, Inc.
//
// This file is part of the Private Internet Access Desktop Client.
//
// The Private Internet Access Desktop Client is free software: you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License as published by the Free Software Foundation, either version 3 of
// the License, or (at your option) any later version.
//
// The Private Internet Access Desktop Client is distributed in the hope that
// it will be useful, but WITHOUT ANY WARRANTY; without even the implied
// warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with the Private Internet Access Desktop Client.  If not, see
// <https://www.gnu.org/licenses/>.

import QtQuick 2.9
import QtQuick.Controls 2.3
import QtQuick.Layouts 1.3
import QtQuick.Window 2.3
import "../common"
import "../core"
import "../daemon"
import "../theme"
import "../settings"
import PIA.NativeHelpers 1.0
import PIA.NativeAcc 1.0 as NativeAcc
import "qrc:/javascript/util.js" as Util

Item {
  id: heroCard
  readonly property int contentTopMargin: 37
  readonly property int contentBottomMargin: 33
  readonly property int contentMarginX: 25

  readonly property int imageWidth: 312
  readonly property int imageMargin: 30

  property string headlineText: uiTr("Welcome to Kyn VPN")
  property string bodyText: uiTr("Thanks for joining us at launch. Here's what this first release includes:")
  property var checkText: [
    uiTr("Fast, modern WireGuard connections"),
    uiTr("Your DNS requests stay inside the VPN tunnel"),
    uiTr("An optional kill switch that blocks traffic if the VPN drops"),
    uiTr("Signed updates, verified before they're installed")
  ]
  property string ctaText: uiTr("VISIT OUR WEBSITE")
  property string heroImageSource: Theme.changelog.heroImage
  property bool ctaEnabled: true
  function onCtaClicked () {
    Qt.openUrlExternally(BrandHelper.getBrandParam("brandWebsiteLink"))
  }

  implicitHeight: {
    var imgb = heroImage.y + heroImage.height + contentBottomMargin
    var textb = heroContent.y + heroContent.height + contentBottomMargin
    return Math.max(imgb, textb)
  }

  Column {
    id: heroContent
    anchors.left: parent.left
    anchors.leftMargin: contentMarginX
    anchors.right: heroImage.left
    anchors.top: parent.top
    anchors.topMargin: contentTopMargin

    StaticText {
      id: featureHeadline
      wrapMode: Text.WordWrap
      width: parent.width
      text: headlineText
      color: Theme.dashboard.textColor
      font.pixelSize: 30
    }

    Item {width: 1; height: 19}

    StaticText {
      id: featureBody
      wrapMode: Text.WordWrap
      width: parent.width
      text: bodyText
      color: Theme.dashboard.textColor
      lineHeight: 24
      lineHeightMode: Text.FixedHeight
      font.pixelSize: 14
    }

    Item {width: 1; height: 16}

    Repeater {
      id: bulletsRepeater
      model: checkText
      delegate: Column {
        Item {width: 1; height: 11}
        Row {
          width: parent.width
          StaticImage {
            id: checkImage
            label: newChangelog.checkBulletLabel
            source: Theme.changelog.wireguardCheckImage
            anchors.top: parent.top
            anchors.topMargin: 5
          }

          // Horizontal spacer
          Item {width: 6; height: 1}

          StaticText {
            color: Theme.dashboard.textColor
            wrapMode: Text.WordWrap
            font.pixelSize: 16
            text: modelData
            width: heroContent.width - checkImage.width - 6
          }
        }
      }
    }

    Item {width: 1; height: 22}

    Item {
      id: ctaButton

      width: Math.max(ctaMessage.contentWidth + 30, 180)
      height: 28

      BorderImage {
        width: Math.max(ctaMessage.contentWidth + 30, 180)
        height: 28
        border {left: 14; top: 14; right: 14; bottom: 14}
        horizontalTileMode: BorderImage.Stretch
        verticalTileMode: BorderImage.Stretch
        source: ctaEnabled ? Theme.changelog.ctaButtonEnabledImage : Theme.changelog.ctaButtonDisabledImage
      }

      Text {
        id: ctaMessage
        anchors.centerIn: parent
        text: ctaText
        color: ctaEnabled ? Theme.changelog.heroCtaTextColor : Theme.changelog.heroCtaDisabledTextColor
      }

      ButtonArea {
        enabled: ctaEnabled
        anchors.fill: parent
        name: ctaText
        cursorShape: Qt.PointingHandCursor
        onClicked: {
          onCtaClicked();
        }
      }
    }
  }

  StaticImage {
    id: heroImage
    //: Screen reader annotation for the launch image in the What's New view
    label: uiTr("Kyn VPN launch")
    anchors.right: parent.right
    anchors.rightMargin: imageMargin
    anchors.top: parent.top
    anchors.topMargin: contentTopMargin
    source: heroImageSource
    width: imageWidth
    height: imageWidth * sourceSize.height / sourceSize.width
  }
}
