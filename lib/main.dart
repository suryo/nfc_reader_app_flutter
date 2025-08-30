import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// NFC
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';
import 'package:nfc_manager/nfc_manager_ios.dart';
import 'package:nfc_manager_ndef/nfc_manager_ndef.dart';

// BLE (RFID)
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

void main() {
  runApp(const NFCAndRFIDApp());
}

class NFCAndRFIDApp extends StatelessWidget {
  const NFCAndRFIDApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NFC & RFID Reader',
      theme: ThemeData(useMaterial3: true),
      home: const HomeTabs(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class HomeTabs extends StatefulWidget {
  const HomeTabs({super.key});

  @override
  State<HomeTabs> createState() => _HomeTabsState();
}

class _HomeTabsState extends State<HomeTabs> with SingleTickerProviderStateMixin {
  late final TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('NFC & RFID Reader'),
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(icon: Icon(Icons.nfc), text: 'NFC (13.56MHz)'),
            Tab(icon: Icon(Icons.bluetooth_searching), text: 'RFID (BLE)'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: const [
          NFCReaderPage(),
          RFIDBlePage(),
        ],
      ),
    );
  }
}

/* =========================
 * ========== NFC ==========
 * ========================= */

class NFCReaderPage extends StatefulWidget {
  const NFCReaderPage({super.key});
  @override
  State<NFCReaderPage> createState() => _NFCReaderPageState();
}

class _NFCReaderPageState extends State<NFCReaderPage> {
  bool _isScanning = false;
  String _status = 'Tekan "Scan NFC", lalu tempelkan kartu/tag ke belakang HP.';
  String? _uidHex;
  String? _tech;
  String? _ndefSummary;

  @override
  void dispose() {
    NfcManager.instance.stopSession();
    super.dispose();
  }

  Future<void> _startScan() async {
    setState(() {
      _isScanning = true;
      _status = 'Memulai sesi NFC...';
      _uidHex = null;
      _tech = null;
      _ndefSummary = null;
    });

    final available = await NfcManager.instance.isAvailable();
    if (!available) {
      setState(() {
        _isScanning = false;
        _status = 'NFC tidak tersedia/aktif di perangkat ini.';
      });
      return;
    }

    await NfcManager.instance.startSession(
      pollingOptions: {NfcPollingOption.iso14443, NfcPollingOption.iso15693},
      onDiscovered: (NfcTag tag) async {
        try {
          final uid = _extractIdentifier(tag);
          final techs = _detectTechs(tag).join(', ');
          final ndefInfo = await _tryReadNdef(tag);

          setState(() {
            _uidHex = uid;
            _tech = techs.isEmpty ? null : techs;
            _ndefSummary = ndefInfo;
            _status = uid == null
                ? 'Tag terdeteksi (UID mungkin tidak diekspos pada tipe/perangkat ini).'
                : 'Tag terdeteksi! UID: $uid';
          });
        } catch (e) {
          setState(() => _status = 'Gagal membaca tag: $e');
        } finally {
          await NfcManager.instance.stopSession();
          if (mounted) setState(() => _isScanning = false);
        }
      },
    );

    setState(() => _status = 'Tempelkan kartu/tag ke belakang HP…');
  }

  Future<void> _stopScan() async {
    await NfcManager.instance.stopSession();
    setState(() {
      _isScanning = false;
      _status = 'Sesi dihentikan.';
    });
  }

  List<String> _detectTechs(NfcTag tag) {
    final t = <String>[];
    try {
      if (NfcAAndroid.from(tag) != null) t.add('NfcA');
      if (NfcBAndroid.from(tag) != null) t.add('NfcB');
      if (NfcFAndroid.from(tag) != null) t.add('NfcF');
      if (NfcVAndroid.from(tag) != null) t.add('NfcV');
      if (IsoDepAndroid.from(tag) != null) t.add('IsoDep');
      if (MifareClassicAndroid.from(tag) != null) t.add('MifareClassic');
      if (MifareUltralightAndroid.from(tag) != null) t.add('MifareUltralight');
      if (NdefAndroid.from(tag) != null) t.add('Ndef');
    } catch (_) {}
    try {
      if (MiFareIos.from(tag) != null) t.add('MiFare');
      if (FeliCaIos.from(tag) != null) t.add('FeliCa');
      if (Iso15693Ios.from(tag) != null) t.add('Iso15693');
      if (Iso7816Ios.from(tag) != null) t.add('Iso7816');
      if (NdefIos.from(tag) != null) t.add('Ndef');
    } catch (_) {}
    return t;
  }

  String? _extractIdentifier(NfcTag tag) {
    Uint8List? id;
    final aTag = NfcTagAndroid.from(tag);
    if (aTag != null) {
      id = aTag.id; // UID Android
    }
    id ??= MiFareIos.from(tag)?.identifier;
    id ??= FeliCaIos.from(tag)?.currentIDm;   // IDm
    id ??= Iso15693Ios.from(tag)?.identifier;
    id ??= Iso7816Ios.from(tag)?.identifier;
    return id == null ? null : _bytesToHex(id);
  }

  Future<String?> _tryReadNdef(NfcTag tag) async {
    final ndef = Ndef.from(tag);
    if (ndef == null) return 'Tag tidak mendukung NDEF.';
    final message = ndef.cachedMessage ?? await ndef.read();
    if (message == null || message.records.isEmpty) return 'NDEF kosong.';
    final buf = StringBuffer();
    for (var i = 0; i < message.records.length; i++) {
      final r = message.records[i];
      buf.writeln('• Record #${i + 1}');
      buf.writeln('  TNF: ${r.typeNameFormat}');
      buf.writeln('  Type: ${String.fromCharCodes(r.type)}');
      if (r.payload.isNotEmpty) {
        final txt = _safePayloadPreview(r.payload);
        buf.writeln('  Payload: $txt');
      }
    }
    return buf.toString().trim();
  }

  String _safePayloadPreview(Uint8List bytes) {
    final s = String.fromCharCodes(bytes);
    return s.length > 120 ? '${s.substring(0, 120)}…' : s;
  }

  String _bytesToHex(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0').toUpperCase());
    }
    return sb.toString();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: [
          if (_uidHex != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: SelectableText(
                        'UID: ${_uidHex!}',
                        style: theme.textTheme.headlineSmall,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Salin UID',
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: _uidHex!));
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('UID disalin ke clipboard')),
                        );
                      },
                      icon: const Icon(Icons.copy),
                    ),
                  ],
                ),
              ),
            ),
          Text(_status, style: theme.textTheme.bodyLarge),
          const SizedBox(height: 16),
          if (_tech != null) _InfoTile(title: 'Tech', value: _tech!),
          if (_ndefSummary != null) _InfoTile(title: 'NDEF', value: _ndefSummary!),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _isScanning ? null : _startScan,
                  icon: const Icon(Icons.nfc),
                  label: const Text('Scan NFC'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _isScanning ? _stopScan : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Catatan: HP hanya bisa NFC 13,56 MHz. RFID 125 kHz/UHF butuh reader eksternal.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/* ============================
 * ========== RFID BLE ========
 * ============================ */

class RFIDBlePage extends StatefulWidget {
  const RFIDBlePage({super.key});
  @override
  State<RFIDBlePage> createState() => _RFIDBlePageState();
}

class _RFIDBlePageState extends State<RFIDBlePage> {
  final _foundDevices = <ScanResult>[];
  BluetoothDevice? _device;
  BluetoothCharacteristic? _notifyChar;
  StreamSubscription<List<int>>? _notifySub;

  final _seenTags = <String>{}; // simpan EPC/ID unik
  final _logs = <String>[];     // log mentah

  bool _isScanning = false;
  bool _isConnected = false;

  // Ganti ini sesuai manual reader kamu:
  static const String targetDeviceName = 'UHF-RFID';      // nama BLE reader
  static final Guid serviceUuid = Guid('0000ffe0-0000-1000-8000-00805f9b34fb'); // contoh
  static final Guid notifyCharUuid = Guid('0000ffe1-0000-1000-8000-00805f9b34fb'); // contoh

  @override
  void dispose() {
    _stopNotifications();
    _device?.disconnect();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() {
      _foundDevices.clear();
      _isScanning = true;
      _device = null;
      _notifyChar = null;
      _seenTags.clear();
      _logs.clear();
    });

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 6));
    FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        // filter sederhana: ada nama dan RSSI oke
        if (r.device.platformName.isNotEmpty && !_foundDevices.any((e) => e.device.remoteId == r.device.remoteId)) {
          _foundDevices.add(r);
        }
      }
      if (mounted) setState(() {});
    });

    await Future.delayed(const Duration(seconds: 7));
    await FlutterBluePlus.stopScan();

    setState(() => _isScanning = false);
  }

  Future<void> _connectTo(ScanResult r) async {
    try {
      await r.device.connect(timeout: const Duration(seconds: 8));
      _device = r.device;
      setState(() => _isConnected = true);

      final services = await r.device.discoverServices();
      for (final s in services) {
        if (s.uuid == serviceUuid) {
          for (final c in s.characteristics) {
            if (c.uuid == notifyCharUuid) {
              _notifyChar = c;
              break;
            }
          }
        }
      }
      if (_notifyChar == null) {
        _log('Characteristic notify tidak ditemukan. Cek UUID service/characteristic.');
        return;
      }

      await _notifyChar!.setNotifyValue(true);
      _notifySub = _notifyChar!.onValueReceived.listen((data) {
        _handleIncomingData(data);
      });

      _log('Terhubung ke ${r.device.platformName} dan subscribe notifikasi.');
    } catch (e) {
      _log('Gagal connect: $e');
      setState(() {
        _isConnected = false;
        _device = null;
      });
    }
  }

  void _stopNotifications() {
    _notifySub?.cancel();
    _notifySub = null;
    if (_notifyChar != null) {
      _notifyChar!.setNotifyValue(false);
    }
  }

  void _handleIncomingData(List<int> data) {
    // Parsing sangat tergantung protokol reader.
    // Banyak reader mengirim ASCII baris per baris (mis. "EPC:3000...;RSSI:-45\n")
    // Di sini, coba decode ASCII dan cari kandidat EPC/ID hex.

    final text = String.fromCharCodes(data);
    _log('RX: $text');

    // Contoh regex sederhana utk string hex panjang (EPC)
    final hexMatches = RegExp(r'([0-9A-Fa-f]{8,})').allMatches(text);
    for (final m in hexMatches) {
      final epc = m.group(1)!.toUpperCase();
      if (_seenTags.add(epc)) {
        if (mounted) setState(() {});
      }
    }
  }

  void _log(String s) {
    _logs.insert(0, '[${DateTime.now().toIso8601String().substring(11,19)}] $s');
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _isScanning ? null : _scan,
                  icon: const Icon(Icons.search),
                  label: const Text('Scan BLE Reader'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _device != null ? () async {
                    _stopNotifications();
                    await _device!.disconnect();
                    setState(() {
                      _isConnected = false;
                      _device = null;
                      _notifyChar = null;
                    });
                  } : null,
                  icon: const Icon(Icons.link_off),
                  label: const Text('Disconnect'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_isScanning) const LinearProgressIndicator(),

          // Daftar device ditemukan
          if (_foundDevices.isNotEmpty) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Perangkat ditemukan:', style: theme.textTheme.titleMedium),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: ListView.separated(
                itemCount: _foundDevices.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (ctx, i) {
                  final r = _foundDevices[i];
                  return ListTile(
                    title: Text(r.device.platformName.isEmpty ? '(no name)' : r.device.platformName),
                    subtitle: Text('${r.device.remoteId.str} • RSSI ${r.rssi}'),
                    trailing: FilledButton(
                      onPressed: _isConnected ? null : () => _connectTo(r),
                      child: const Text('Connect'),
                    ),
                  );
                },
              ),
            ),
          ] else
            Expanded(
              child: Center(
                child: Text(
                  'Klik "Scan BLE Reader" lalu pilih reader UHF/LF Anda.\n'
                  'Catatan: HP tidak bisa baca RFID 125kHz/UHF tanpa reader eksternal.',
                  style: theme.textTheme.bodyMedium, textAlign: TextAlign.center,
                ),
              ),
            ),

          const SizedBox(height: 12),

          // Info koneksi + daftar tag terbaca
          if (_device != null) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _isConnected ? 'Terhubung: ${_device!.platformName}' : 'Menghubungkan…',
                style: theme.textTheme.titleMedium,
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Tag terbaca (${_seenTags.length}):', style: theme.textTheme.titleSmall),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 140,
              child: Card(
                child: ListView.separated(
                  padding: const EdgeInsets.all(8),
                  itemCount: _seenTags.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (ctx, i) {
                    final epc = _seenTags.elementAt(i);
                    return Row(
                      children: [
                        Expanded(child: Text(epc, style: theme.textTheme.bodyMedium)),
                        IconButton(
                          tooltip: 'Salin',
                          icon: const Icon(Icons.copy),
                          onPressed: () async {
                            await Clipboard.setData(ClipboardData(text: epc));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('EPC disalin')),
                            );
                          },
                        )
                      ],
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Log:', style: theme.textTheme.titleSmall),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 140,
              child: Card(
                child: ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.all(8),
                  itemCount: _logs.length,
                  itemBuilder: (ctx, i) => Text(_logs[i], style: theme.textTheme.bodySmall),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/* ====== Shared UI ====== */

class _InfoTile extends StatelessWidget {
  final String title;
  final String value;
  const _InfoTile({required this.title, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: SelectableText.rich(
          TextSpan(
            children: [
              TextSpan(text: '$title\n', style: theme.textTheme.titleSmall),
              TextSpan(text: value, style: theme.textTheme.bodyMedium),
            ],
          ),
        ),
      ),
    );
  }
}
