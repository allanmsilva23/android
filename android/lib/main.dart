import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';

import 'package:polygonid_flutter_sdk/sdk/polygon_id_sdk.dart';
import 'package:polygonid_flutter_sdk/common/domain/entities/env_entity.dart';
import 'package:polygonid_flutter_sdk/common/domain/entities/chain_config_entity.dart';
import 'package:polygonid_flutter_sdk/common/domain/domain_constants.dart';
import 'package:polygonid_flutter_sdk/iden3comm/domain/entities/common/iden3_message_entity.dart';
import 'package:polygonid_flutter_sdk/iden3comm/domain/entities/credential/request/base.dart';
import 'package:polygonid_flutter_sdk/identity/domain/exceptions/identity_exceptions.dart';




Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final cacheDir = (await getTemporaryDirectory()).path;

  final env = EnvEntity(
    cacheDir: cacheDir,
    pushUrl: 'https://push-staging.polygonid.com/api/v1',
    ipfsUrl: 'https://ipfs.infura.io:5001',
    ipfsGatewayUrl: 'https://ipfs.io',
    didResolverUrl: null,
    stacktraceEncryptionKey: '',	
    method: 'iden3',
    chainConfigs: {
      "80002": ChainConfigEntity(
        blockchain: 'polygon',
        network: 'amoy',
        rpcUrl: 'https://rpc-amoy.polygon.technology/',
        stateContractAddr: '0x1a4cC30f2aA0377b0c3bc9848766D90cb4404124',
        method: 'iden3',
      ),
    },

    didMethods: const [],
  );

  await PolygonIdSdk.init(env: env);
 
  PolygonIdSdk.I.proof.proofGenerationStepsStream().listen((step) {
    dev.log(step, name: 'SSI');
  });

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Privado SSI PoC',
      theme: ThemeData(useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _secure = FlutterSecureStorage();
  static const _kDid = 'genesisDid';
  static const _kPk = 'privateKey';

  String? _did;
  String? _pk;

  List<dynamic> _claims = [];

  bool _busy = false;
  String _status = 'Ready';

 

  void _logErr(String where, Object err, StackTrace st) {
    dev.log('❌ $where: $err', name: 'SSI', error: err, stackTrace: st);
    debugPrint('❌ $where: $err');
    debugPrintStack(label: 'STACK ($where)', stackTrace: st);
  }

  T? _try<T>(T Function() fn) {
    try {
      return fn();
    } catch (_) {
      return null;
    }
  }

  String _prettyJson(dynamic raw) {
    try {
      return JsonEncoder.withIndent('  ').convert(raw);
    } catch (_) {
      return raw.toString();
    }
  }

  @override
  void initState() {
    super.initState();
    _loadIdentity().then((_) => _loadClaims());
  }

  // armaz. e identidade

  Future<void> _loadIdentity() async {
    final did = await _secure.read(key: _kDid);
    final pk  = await _secure.read(key: _kPk);

    if (!mounted) return;
    setState(() {
      _did = did;
      _pk  = pk;
    });

    if (did != null && pk != null) {
      await _loadClaims(); // caarregamento automático das creds
    }
  }

  Future<void> _resetIdentity() async {
    await _secure.delete(key: _kDid);
    await _secure.delete(key: _kPk);

    if (!mounted) return;
    setState(() {
      _did = null;
      _pk = null;
      _claims = [];
      _status = 'Identity reset ✅ (SDK DB may still exist; clear app storage for full reset)';
    });
  }

  Future<void> _createIdentity() async {
    setState(() {
      _busy = true;
      _status = 'Creating identity...';
    });

    try {
     
      final identity = await PolygonIdSdk.I.identity.addIdentity();

      final did = identity.did;
      final pk = identity.privateKey;

      await _secure.write(key: _kDid, value: did);
      await _secure.write(key: _kPk, value: pk);

      if (!mounted) return;
      setState(() {
        _did = did;
        _pk = pk;
        _status = 'Identity created ✅';
      });

      dev.log('✅ DID: $did', name: 'SSI');

      await _loadClaims();
    } catch (e, st) {
      _logErr('_createIdentity', e, st);
      if (mounted) setState(() => _status = 'Create identity error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // inicio de trabalho com circuitos- verificação de authv2.zkey no smartphone. Essa parte é importante, especialmente para a geração de provas

  Future<bool> _ensureAuthV2ZkeyOnDisk() async {
    final dir = await getApplicationDocumentsDirectory();
    final out = File('${dir.path}/authV2.zkey');

    if (out.existsSync() && out.lengthSync() > 0) return true;

    final data = await rootBundle.load('assets/authV2.zkey');
    await out.writeAsBytes(data.buffer.asUint8List(), flush: true);

    return out.existsSync() && out.lengthSync() > 0;
  }

  //creds

  Future<void> _loadClaims() async {
    try {
      if (_did == null || _pk == null) return;

      final claims = await PolygonIdSdk.I.credential.getClaims(
        genesisDid: _did!,
        privateKey: _pk!,
        
      );

      if (!mounted) return;
      setState(() {
        _claims = claims;
        _status = 'Loaded ${claims.length} creds ✅';
      });
    } catch (e, st) {
      _logErr('_loadClaims', e, st);
      if (!mounted) return;
      setState(() => _status = 'Load claims error: $e');
    }
  }

  // fluxo qr

  Future<void> _scanQr() async {
    if (_did == null || _pk == null) {
      setState(() => _status = 'Create identity first');
      return;
    }

    final scanned = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScanPage()),
    );

    if (scanned == null || scanned.isEmpty) return;
    await _handleScanned(scanned);
  }

  Future<void> _handleScanned(String scanned) async {
    if (_did == null || _pk == null) return;

    setState(() {
      _busy = true;
      _status = 'Parsing QR...';
    });

    try {
      final rawJson = await _resolveQrToRawIden3Message(scanned);

      final Iden3Message msg =
      await PolygonIdSdk.I.iden3comm.getIden3Message(message: rawJson);

      if (msg.type == Iden3MessageType.credentialOffer &&
          msg is BaseCredentialOfferMessage) {
        setState(() => _status = 'Credential offer detected ✅ Preparing authV2...');

        final ok = await _ensureAuthV2ZkeyOnDisk();
        if (!ok) {
          setState(() => _status = 'Missing authV2.zkey ❌ (check assets/pubspec)');
          return;
        }

        setState(() => _status = 'Fetching credential from issuer...');

        final creds = await PolygonIdSdk.I.iden3comm.fetchAndSaveClaims(
          message: msg,
          genesisDid: _did!,
          profileNonce: GENESIS_PROFILE_NONCE,
          privateKey: _pk!,
          keys: const [], // na branch develop do sdk, temos que passar um argumento pra esse parâmetro
        );

        setState(() => _status = 'Saved ${creds.length} credential(s) ✅');
        await _loadClaims();
        return;
      }

      setState(() => _status = 'Unsupported message type: ${msg.type}');
    } catch (e, st) {
      if (e is DidNotMatchCurrentEnvException) {
        debugPrint('[SSI] DID mismatch.');
        debugPrint('[SSI] Yours: ${e.did}');
        debugPrint('[SSI] Expected: ${e.rightDid}');
      }

      _logErr('_handleScanned', e, st);
      if (mounted) setState(() => _status = 'QR handling error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String> _resolveQrToRawIden3Message(String scanned) async {
    final s = scanned.trim();

    if (s.startsWith('{') && s.endsWith('}')) return s;

    final uri = Uri.tryParse(s);
    if (uri == null) return s;

    if (uri.scheme == 'iden3comm') {
      final requestUri = uri.queryParameters['request_uri'];
      if (requestUri == null || requestUri.isEmpty) {
        throw Exception('iden3comm:// missing request_uri');
      }

      final decoded = Uri.decodeComponent(requestUri);
      final url = Uri.parse(decoded);

      final resp = await http.get(url);
      if (resp.statusCode != 200) {
        throw Exception('request_uri HTTP ${resp.statusCode}: ${resp.body}');
      }

      return resp.body;
    }

    return s;
  }

  //ui- simples, mas funcional

  @override
  Widget build(BuildContext context) {
    final canScan = !_busy && _did != null && _pk != null;

    return Scaffold(
      appBar: AppBar(title: const Text('Privado SSI PoC')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('StatUS: $_status'),
            const SizedBox(height: 12),
            SelectableText('DID: ${_did ?? "-"}'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                ElevatedButton(
                  onPressed: _busy ? null : _createIdentity,
                  child: const Text('Create DID'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : _resetIdentity,
                  child: const Text('Reset Identity'),
                ),
                ElevatedButton(
                  onPressed: canScan ? _scanQr : null,
                  child: const Text('Scan issuer QR'),
                ),
              ],
            ),
            const SizedBox(height: 16),

            Row(
              children: [
                Text('Credentials (${_claims.length})',
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  onPressed: _busy ? null : _loadClaims,
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh',
                ),
              ],
            ),
            const SizedBox(height: 8),

            Expanded(
              child: _claims.isEmpty
                  ? const Text('No credentials saved yet.')
                  : ListView.separated(
                itemCount: _claims.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final c = _claims[i];

                  final id = _try(() => (c as dynamic).id) ??
                      _try(() => (c as dynamic).claimId) ??
                      '';

                  final issuer = _try(() => (c as dynamic).issuer) ??
                      _try(() => (c as dynamic).issuerDid) ??
                      _try(() => (c as dynamic).from) ??
                      '';

                  final schema = _try(() => (c as dynamic).schema) ??
                      _try(() => (c as dynamic).schemaHash) ??
                      _try(() => (c as dynamic).type) ??
                      '';

                  final expiration = _try(() => (c as dynamic).expiration) ??
                      _try(() => (c as dynamic).expirationDate) ??
                      '';

                  final subtitleLines = <String>[
                    if (issuer.toString().isNotEmpty) 'issuer: $issuer',
                    if (id.toString().isNotEmpty) 'id: $id',
                    if (expiration.toString().isNotEmpty) 'exp: $expiration',
                  ];

                  return ListTile(
                    title: Text(
                      schema.toString().isEmpty ? 'Credential #$i' : schema.toString(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      subtitleLines.join('\n'),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () async {
                      final raw = _try(() => (c as dynamic).toJson?.call());

                      await showDialog(
                        context: context,
                        builder: (_) => AlertDialog(
                          title: const Text('Credential (raw)'),
                          content: SingleChildScrollView(
                            child: SelectableText(
                              raw == null ? c.toString() : _prettyJson(raw),
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Close'),
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),

            const SizedBox(height: 12),
            const Text('TEsts Privado'),
          ],
        ),
      ),
    );
  }
}

class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key});
  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan QR')),
      body: MobileScanner(
        onDetect: (capture) {
          if (_done) return;

          final code = capture.barcodes.isNotEmpty
              ? capture.barcodes.first.rawValue
              : null;

          if (code == null || code.isEmpty) return;

          _done = true;
          Navigator.of(context).pop(code);
        },
      ),
    );
  }
}