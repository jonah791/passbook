import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:passbook/core/sync_lan.dart';

/// 局域网自动发现。
///
/// 这一层要挡的是两类错：
/// ① **把别人的包当成设备**——发现端口是个固定端口，同一台机器上还有几十个
///    程序在发包，收到就列出来等于给用户一张假名单。
/// ② **把别人的话当成可信内容**——机器名是网线上来的，可能带控制字符、
///    可能超长，界面上要原样显示它，那条路必须先把脏东西剔掉。
void main() {
  Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

  group('回应解析', () {
    test('一台正常回应的名字和端口', () {
      final peer = DiscoveredPeer.tryParse(
        '192.168.50.214',
        bytes('PASSBOOK-HERE/1 {"name":"DESKTOP-ABC","port":7901}'),
      );
      expect(peer, isNotNull);
      expect(peer!.host, '192.168.50.214');
      expect(peer.name, 'DESKTOP-ABC');
      expect(peer.port, 7901);
    });

    test('地址取自包的源地址，不是对端自报的', () {
      // 就算是同一句回应，host 也只能来自 datagram.address —— 那个由系统填。
      final peer = DiscoveredPeer.tryParse(
        '10.0.0.9',
        bytes('PASSBOOK-HERE/1 {"name":"x","port":7901}'),
      );
      expect(peer!.host, '10.0.0.9');
    });

    test('没有前缀的包不认', () {
      expect(
        DiscoveredPeer.tryParse('10.0.0.9', bytes('{"name":"x","port":7901}')),
        isNull,
      );
    });

    test('前缀对但 JSON 坏掉不认', () {
      expect(
        DiscoveredPeer.tryParse('10.0.0.9', bytes('PASSBOOK-HERE/1 {oops')),
        isNull,
      );
    });

    test('端口越界不认', () {
      for (final port in [0, -1, 70000]) {
        expect(
          DiscoveredPeer.tryParse(
            '10.0.0.9',
            bytes('PASSBOOK-HERE/1 {"name":"x","port":$port}'),
          ),
          isNull,
          reason: 'port=$port 不该被当成设备',
        );
      }
    });

    test('端口不是整数不认', () {
      expect(
        DiscoveredPeer.tryParse(
          '10.0.0.9',
          bytes('PASSBOOK-HERE/1 {"name":"x","port":"7901"}'),
        ),
        isNull,
      );
    });

    test('名字带控制字符时剔掉，只留可显示的', () {
      final peer = DiscoveredPeer.tryParse(
        '10.0.0.9',
        bytes('PASSBOOK-HERE/1 {"name":"AB\\u0000C\\u001fD","port":7901}'),
      );
      expect(peer!.name, 'ABCD');
    });

    test('名字超长时截断到 64 字', () {
      final long = 'A' * 200;
      final peer = DiscoveredPeer.tryParse(
        '10.0.0.9',
        bytes('PASSBOOK-HERE/1 {"name":"$long","port":7901}'),
      );
      expect(peer!.name.length, 64);
    });

    test('名字为空时退回用地址显示', () {
      final peer = DiscoveredPeer.tryParse(
        '10.0.0.9',
        bytes('PASSBOOK-HERE/1 {"name":"","port":7901}'),
      );
      expect(peer!.name, '10.0.0.9');
    });
  });

  group('连接失败的说法', () {
    test('端口没有服务在听', () {
      final text = explainSocketFailure(
        const SocketException(
          'err',
          osError: OSError('Connection refused', 10061),
        ),
        host: '192.168.50.214',
        port: 57188,
      );
      expect(text, contains('192.168.50.214:57188'));
      expect(text, contains('没有服务在听'));
    });

    test('地址到不了（VPN / 不同网络 / 网卡不在线）', () {
      final text = explainSocketFailure(
        const SocketException(
          'err',
          osError: OSError('No route to host', 113),
        ),
        host: '192.168.50.214',
        port: 7901,
      );
      expect(text, contains('到不了'));
      expect(text, contains('VPN'));
    });

    test('超时提示防火墙', () {
      final text = explainSocketFailure(
        const SocketException(
          'err',
          osError: OSError('Connection timed out', 10060),
        ),
        host: '10.0.0.2',
        port: 7901,
      );
      expect(text, contains('超时'));
      expect(text, contains('防火墙'));
    });

    test('认不出的错误也把原始信息与错误码留下', () {
      final text = explainSocketFailure(
        const SocketException(
          'err',
          osError: OSError('something weird', 9999),
        ),
        host: '10.0.0.2',
        port: 7901,
      );
      expect(text, contains('something weird'));
      expect(text, contains('9999'));
    });
  });

  group('真实往返', () {
    test('一台 announce 之后，另一台 scan 能把它捞出来', () async {
      RawDatagramSocket socket;
      try {
        socket = await LanDiscovery.announce(syncPort: 34567, name: 'test-peer');
      } on SocketException {
        markTestSkipped('本机不允许绑定发现端口，跳过真实往返');
        return;
      }
      addTearDown(socket.close);
      final peers = await LanDiscovery.scan(
        window: const Duration(milliseconds: 400),
      );
      final self = peers.where((p) => p.port == 34567).toList();
      expect(self, isNotEmpty, reason: '广播发出去了却没收到自己的回应');
      expect(self.first.name, 'test-peer');
    });
  });
}
