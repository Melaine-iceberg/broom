import 'package:flutter/foundation.dart';

import '../core/rules/rule_catalog.dart';
import '../core/rules/rule_update_service.dart';
import '../l10n/broom_strings.dart';
import 'settings_controller.dart';

class RuleUpdateController extends ChangeNotifier {
  RuleUpdateController({
    required this.service,
    required this.settings,
    required this.onCatalogChanged,
  });

  final RuleUpdateService service;
  final SettingsController settings;
  final void Function(RuleCatalog catalog) onCatalogChanged;

  bool _busy = false;
  String? _error;
  String? _notice;
  RuleUpdateCandidate? _candidate;
  bool _disposed = false;

  bool get busy => _busy;
  String? get error => _error;
  String? get notice => _notice;
  RuleUpdateCandidate? get candidate => _candidate;
  bool get updatesEnabled => service.updatesEnabled;
  bool get hasPrevious => service.store.hasPrevious;
  RuleCatalog get activeCatalog => service.store.current;
  String? get storeError => service.store.loadError;
  String get updateUrl => settings.settings.ruleUpdateUrl;

  Future<String?> saveUrl(String url) async {
    final error = await settings.setRuleUpdateUrl(url);
    if (error != null) _error = error;
    _notify();
    return error;
  }

  Future<void> checkForUpdates() async {
    if (_busy) return;
    _busy = true;
    _error = null;
    _notice = null;
    _candidate = null;
    _notify();
    try {
      final uri = Uri.tryParse(updateUrl.trim());
      if (uri == null || uri.scheme != 'https') {
        throw const RuleUpdateException('请先填写有效的 HTTPS 规则更新地址。');
      }
      final candidate = await service.checkForUpdates(uri);
      if (candidate == null) {
        _notice = tr('当前规则已是最新版本。');
      } else {
        _candidate = candidate;
        _notice = trf('发现规则版本 {version}，确认后可应用。', {
          'version': candidate.manifestVersion,
        });
      }
    } on RuleUpdateException catch (error) {
      _error = error.message;
    } catch (error) {
      _error = trf('规则更新检查失败：{error}', {'error': error});
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<void> applyUpdate() async {
    final candidate = _candidate;
    if (_busy || candidate == null) return;
    _busy = true;
    _error = null;
    _notice = null;
    _notify();
    try {
      final catalog = await service.apply(candidate);
      onCatalogChanged(catalog);
      _candidate = null;
      _notice = trf('已启用规则版本 {version}。', {'version': catalog.version});
    } catch (error) {
      _error = trf('无法启用规则更新：{error}', {'error': error});
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<void> rollback() async {
    if (_busy) return;
    _busy = true;
    _error = null;
    _notice = null;
    _notify();
    try {
      final catalog = await service.rollback();
      if (catalog == null) {
        _error = tr('没有可回滚的规则版本。');
      } else {
        onCatalogChanged(catalog);
        _candidate = null;
        _notice = trf('已回滚到规则版本 {version}。', {'version': catalog.version});
      }
    } catch (error) {
      _error = trf('规则回滚失败：{error}', {'error': error});
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<void> restoreBuiltin() async {
    if (_busy) return;
    _busy = true;
    _error = null;
    _notice = null;
    _notify();
    try {
      final catalog = await service.restoreBuiltin();
      onCatalogChanged(catalog);
      _candidate = null;
      _notice = tr('已恢复内置规则，上一版本保留用于回滚。');
    } catch (error) {
      _error = trf('无法恢复内置规则：{error}', {'error': error});
    } finally {
      _busy = false;
      _notify();
    }
  }

  void clearMessages() {
    _error = null;
    _notice = null;
    _notify();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
