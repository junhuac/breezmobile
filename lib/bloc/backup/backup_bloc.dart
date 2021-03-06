import 'dart:async';
import 'dart:convert';
import 'package:breez/bloc/backup/backup_model.dart';
import 'package:breez/services/injector.dart';
import 'package:rxdart/rxdart.dart';
import 'package:breez/services/breezlib/breez_bridge.dart';
import 'package:breez/services/breezlib/data/rpc.pb.dart';
import 'package:breez/services/backup.dart';
import 'package:breez/bloc/account/account_model.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

class BackupBloc {
  BackupService _service;
  Stream<AccountModel> _accountStream;
  Stream<String> _backupIDStream;

  String _currentNodeId;

  final BehaviorSubject<List<String>> _availableBackupPathsController =
      new BehaviorSubject<List<String>>();
  Stream<List<String>> get availableBackupPathsStream =>
      _availableBackupPathsController.stream;

  final BehaviorSubject<DateTime> _lastBackupTimeController =
      new BehaviorSubject<DateTime>();
  Stream<DateTime> get lastBackupTimeStream => _lastBackupTimeController.stream;

  final BehaviorSubject<BackupSettings> _backupSettingsController =
      new BehaviorSubject<BackupSettings>(seedValue: BackupSettings.start());
  Stream<BackupSettings> get backupSettingsStream =>
      _backupSettingsController.stream;
  Sink<BackupSettings> get backupSettingsSink => _backupSettingsController.sink;

  final _backupNowController = new StreamController<bool>();
  Sink<bool> get backupNowSink => _backupNowController.sink;

  final _restoreRequestController = new StreamController<String>();
  Sink<String> get restoreRequestSink => _restoreRequestController.sink;

  final _multipleRestoreController =
      new StreamController<Map<String, String>>.broadcast();
  Stream<Map<String, String>> get multipleRestoreStream =>
      _multipleRestoreController.stream;

  final _restoreFinishedController = new StreamController<bool>.broadcast();
  Stream<bool> get restoreFinishedStream => _restoreFinishedController.stream;

  BreezBridge _breezLib;
  SharedPreferences _sharedPrefrences;  
  String _backupBreezID;

  static const String BACKUP_SETTINGS_PREFERENCES_KEY = "backup_settings";
  static const String AVAILABLE_PATHS_PREFERENCE_KEY = "backup_available_paths";
  static const String LAST_BACKUP_TIME_PREFERENCE_KEY = "backup_last_time";

  BackupBloc(this._accountStream, this._backupIDStream) {
    ServiceInjector injector = new ServiceInjector();
    _breezLib = injector.breezBridge;
    _service = injector.backupService;

    SharedPreferences.getInstance().then((sp) {
      _sharedPrefrences = sp;
      _accountStream.listen((acc) => _currentNodeId = acc.id);
      _backupIDStream.listen((backupID) => _backupBreezID = backupID);
      _initializePersistentData();
      _listenBackupPaths();
      _listenBackupNowRequests();
      _listenRestoreRequests();
    });
  }

  void _initializePersistentData() {
    //paths persistency
    List<String> paths =
        _sharedPrefrences.getStringList(AVAILABLE_PATHS_PREFERENCE_KEY);
    if (paths != null && paths.length > 0) {
      _backupNow();
    }    
    
    _availableBackupPathsController.stream.listen((backupPaths) {
      _sharedPrefrences.setStringList(
          AVAILABLE_PATHS_PREFERENCE_KEY, backupPaths);
    });

    //last backup time persistency
    int lastTime = _sharedPrefrences.getInt(LAST_BACKUP_TIME_PREFERENCE_KEY);
    if (lastTime != null) {
      _lastBackupTimeController
          .add(DateTime.fromMillisecondsSinceEpoch(lastTime));
    }
    _lastBackupTimeController.stream.listen((lastTime) {
      _sharedPrefrences.setInt(
          LAST_BACKUP_TIME_PREFERENCE_KEY, lastTime.millisecondsSinceEpoch);
    });

    //settings persistency
    var backupSettings =
        _sharedPrefrences.getString(BACKUP_SETTINGS_PREFERENCES_KEY);
    if (backupSettings != null) {
      Map<String, dynamic> settings = json.decode(backupSettings);
      _backupSettingsController.add(BackupSettings.fromJson(settings));
    }
    _backupSettingsController.stream.listen((settings) {
      _sharedPrefrences.setString(
          BACKUP_SETTINGS_PREFERENCES_KEY, json.encode(settings.toJson()));
    });
  }

  void _listenBackupNowRequests() {
    _backupNowController.stream.listen((_) => _backupNow());
  }

  bool _backupNowRequested = false;
  _backupNow(){
    _backupNowRequested = true;
    _breezLib.backup();
  }

  _listenBackupPaths() {
    Observable(_breezLib.notificationStream).where((event) {
      return event.type ==
          NotificationEvent_NotificationType.BACKUP_FILES_AVAILABLE;
    }).listen((event) {
      _availableBackupPathsController.add(event.data);
    });

    _availableBackupPathsController.stream
        .where((paths) => paths != null)
        .listen((paths) {
      backup(paths, _currentNodeId, !_backupNowRequested);
      _backupNowRequested = false;
    });
  }

  void _listenRestoreRequests() {
    _restoreRequestController.stream.listen((nodeId) {
      if (nodeId == null || nodeId.isEmpty) {
        _service.signOut().then((_) {
          return _service.getAvailableBackups();
        }).then((backups) {
          _multipleRestoreController.add(new Map<String, String>.from(backups));
        }).catchError((error) {
          _restoreFinishedController.addError(error);
        });
        return;
      }

      _service.restore(nodeId, _backupBreezID).then((restoreResult) {
        return _breezLib.bootstrap().then((done) {
          return getApplicationDocumentsDirectory().then((appDir) {
            return _breezLib.copyBreezConfig(appDir.path).then((done) {
              return _breezLib
                  .bootstrapFiles(
                      appDir.path, new List<String>.from(restoreResult))
                  .then((done) {
                _restoreFinishedController.add(true);
              });
            });
          });
        });
      }).catchError((error) {
        _restoreFinishedController.addError(error);
      });
    });
  }

  void backup(List<String> backupPaths, String nodeId, bool silent) {
    _service
        .backup(backupPaths, nodeId, _backupBreezID, silent: silent)
        .then((_) {
      _availableBackupPathsController.add(null);
      _lastBackupTimeController.add(DateTime.now());
    }).catchError((error) {
      _lastBackupTimeController.addError(error);
    });
  }

  close() {
    _backupNowController.close();
    _restoreRequestController.close();
    _multipleRestoreController.close();
    _restoreFinishedController.close();
    _availableBackupPathsController.close();
    _backupSettingsController.close();
  }
}
