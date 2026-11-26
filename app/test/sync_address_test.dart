import 'package:flutter_test/flutter_test.dart';
import 'package:passbook/core/sync_lan.dart';

/// 同步页上两个「照抄就错」的东西：显示的地址从哪来、失败时怎么说。
///
/// 2026-11-26 实测：Windows 上装了 WSL，同步页「这台设备」列出的是
/// 172.19.0.1（vEthernet 的地址），另一台设备照着连，拿回一个 502，
/// 而错误信息后面什么都没有——用户看到的是一句没有原因的话。
void main() {
  group('虚拟网卡识别', () {
    test('WSL 的适配器名算虚拟', () {
      expect(LanSync.isVirtualNicName('vEthernet (WSL)'), isTrue);
      expect(LanSync.isVirtualNicName('vEthernet (Default Switch)'), isTrue);
    });

    test('容器 / 虚拟机 / 组网工具的都算', () {
      expect(LanSync.isVirtualNicName('Docker Desktop'), isTrue);
      expect(LanSync.isVirtualNicName('VMware Network Adapter VMnet8'), isTrue);
      expect(LanSync.isVirtualNicName('VirtualBox Host-Only Network'), isTrue);
      expect(LanSync.isVirtualNicName('Tailscale'), isTrue);
      expect(LanSync.isVirtualNicName('ZeroTier One'), isTrue);
    });

    test('真实网卡不算虚拟', () {
      expect(LanSync.isVirtualNicName('WLAN'), isFalse);
      expect(LanSync.isVirtualNicName('Wi-Fi'), isFalse);
      expect(LanSync.isVirtualNicName('以太网'), isFalse);
      expect(LanSync.isVirtualNicName('Ethernet 2'), isFalse);
    });

    test('链路本地地址（169.254）不可跨设备，要剔掉', () {
      expect(LanSync.isLinkLocalV4('169.254.24.119'), isTrue);
      expect(LanSync.isLinkLocalV4('169.254.1.1'), isTrue);
      expect(LanSync.isLinkLocalV4('192.168.50.204'), isFalse);
      expect(LanSync.isLinkLocalV4('10.0.0.5'), isFalse);
      expect(LanSync.isLinkLocalV4('169.255.1.1'), isFalse);
    });
  });

  group('失败说明', () {
    test('对方给了原话就照登', () {
      expect(explainSyncFailure(403, '配对码不对'), '：配对码不对');
    });

    test('502 且没有正文时，要指出它可能来自代理', () {
      final text = explainSyncFailure(502, '');
      expect(text, contains('代理'));
      expect(text, contains('直连'));
      // 判据：不能只剩一个冒号——那就是用户当时看到的全部信息。
      expect(text.trim(), isNot('：'));
      expect(text.length, greaterThan(20));
    });

    test('404 指向「端口上不是这个服务」', () {
      expect(explainSyncFailure(404, ''), contains('端口'));
    });

    test('没见过的状态码也给一句话，不留空', () {
      expect(explainSyncFailure(418, '').trim().length, greaterThan(3));
    });
  });
}
