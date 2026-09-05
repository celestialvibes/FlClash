part of '../action.dart';

@Riverpod(keepAlive: true)
class ProfilesAction extends _$ProfilesAction {
  final _mutations = <int, (SerialTaskScheduler, int)>{};

  Future<T> mutateProfile<T>(
    int id,
    Future<T> Function(Profile current) action,
  ) async {
    final (scheduler, users) = _mutations[id] ?? (SerialTaskScheduler(), 0);
    _mutations[id] = (scheduler, users + 1);
    try {
      return await scheduler.run(() async {
        final current = ref.read(profilesProvider).getProfile(id);
        if (current == null) throw StateError('Profile no longer exists');
        return action(current);
      });
    } finally {
      final remaining = _mutations[id]!.$2 - 1;
      if (remaining == 0) {
        _mutations.remove(id);
      } else {
        _mutations[id] = (scheduler, remaining);
      }
    }
  }

  @override
  void build() {}

  void updateCurrentSelectedMap(String groupName, String proxyName) {
    final currentProfile = ref.read(currentProfileProvider);
    if (currentProfile != null &&
        currentProfile.selectedMap[groupName] != proxyName) {
      final selectedMap = Map<String, String>.from(currentProfile.selectedMap)
        ..[groupName] = proxyName;
      ref
          .read(profilesProvider.notifier)
          .put(currentProfile.copyWith(selectedMap: selectedMap));
    }
  }

  Future<void> deleteProfile(int id) => mutateProfile(id, (_) async {
    await ref.read(profilesProvider.notifier).del(id);
    await clearEffect(id);
    final currentProfileId = ref.read(currentProfileIdProvider);
    if (currentProfileId == id) {
      final profiles = ref.read(profilesProvider);
      if (profiles.isNotEmpty) {
        final updateId = profiles.first.id;
        ref.read(currentProfileIdProvider.notifier).value = updateId;
      } else {
        ref.read(currentProfileIdProvider.notifier).value = null;
        ref.read(setupActionProvider.notifier).setRunning(false);
      }
    }
  });

  Future<void> autoUpdateProfiles() async {
    for (final profile in ref.read(profilesProvider)) {
      if (!profile.autoUpdate) continue;
      final isNotNeedUpdate = profile.lastUpdateDate
          ?.add(profile.autoUpdateDuration)
          .isBeforeNow;
      if (isNotNeedUpdate == false || profile.type == ProfileType.file) {
        continue;
      }
      try {
        await updateProfile(profile);
      } catch (e) {
        commonPrint.log(e.toString(), logLevel: LogLevel.warning);
      }
    }
  }

  void putProfile(Profile profile) {
    ref.read(profilesProvider.notifier).put(profile);
    if (ref.read(currentProfileIdProvider) != null) return;
    ref.read(currentProfileIdProvider.notifier).value = profile.id;
  }

  Future<void> updateProfiles() async {
    for (final profile in ref.read(profilesProvider)) {
      if (profile.type == ProfileType.file) continue;
      await updateProfile(profile);
    }
  }

  @protected
  Future<Profile> downloadProfile(Profile profile) => profile.update();

  Future<void> updateProfile(
    Profile profile, {
    bool showLoading = false,
    bool rollbackOnFailure = false,
    bool updateMetadata = false,
  }) {
    return mutateProfile(profile.id, (current) async {
      final requested = updateMetadata
          ? current.copyWith(
              url: profile.url,
              label: profile.label,
              autoUpdate: profile.autoUpdate,
              autoUpdateDuration: profile.autoUpdateDuration,
            )
          : current;
      try {
        if (showLoading) {
          ref.read(isUpdatingProvider(profile.updatingKey).notifier).value =
              true;
        }
        ref.read(profilesProvider.notifier).put(requested);
        final downloaded = await downloadProfile(requested);
        if (!ref.mounted) return;
        final latest = ref.read(profilesProvider).getProfile(profile.id);
        if (latest == null) return;
        ref
            .read(profilesProvider.notifier)
            .put(
              latest.copyWith(
                label: latest.label == requested.label
                    ? downloaded.label
                    : latest.label,
                subscriptionInfo: downloaded.subscriptionInfo,
                lastUpdateDate: downloaded.lastUpdateDate,
              ),
            );
        if (profile.id == ref.read(currentProfileIdProvider)) {
          ref
              .read(setupActionProvider.notifier)
              .applyProfileDebounce(silence: true);
        }
      } catch (_) {
        if (rollbackOnFailure && ref.mounted) {
          final latest = ref.read(profilesProvider).getProfile(profile.id);
          if (latest != null) {
            ref
                .read(profilesProvider.notifier)
                .put(latest.copyWith(url: current.url));
          }
        }
        rethrow;
      } finally {
        if (ref.mounted) {
          ref.read(isUpdatingProvider(profile.updatingKey).notifier).value =
              false;
        }
      }
    });
  }

  Future<void> addProfileFormFile() async {
    final platformFile = await globalState.safeRun(picker.pickerFile);
    if (platformFile == null) return;
    final bytes = await platformFile.readBytes();
    globalState.navigatorKey.currentState?.popUntil((route) => route.isFirst);
    ref.read(currentPageLabelProvider.notifier).toProfiles();
    final profile = await globalState.loadingRun(
      tag: LoadingTag.profiles,
      () async {
        return Profile.normal(label: platformFile.name).saveFile(bytes);
      },
      title: currentAppLocalizations.addProfile,
    );
    if (profile != null) {
      putProfile(profile);
    }
  }

  Future<bool> addProfileFormURL(
    String url, {
    bool showError = true,
    void Function(Object error)? onError,
  }) async {
    Future<T> captureError<T>(Future<T> Function() action) async {
      try {
        return await action();
      } catch (error) {
        onError?.call(error);
        rethrow;
      }
    }

    if (globalState.navigatorKey.currentState?.canPop() ?? false) {
      globalState.navigatorKey.currentState?.popUntil((route) => route.isFirst);
    }
    final currentProfile = ref.read(currentProfileProvider);
    if (currentProfile != null) {
      final updated = await globalState.safeRun(() async {
        await captureError(
          () => updateProfile(
            currentProfile.copyWith(url: url),
            showLoading: true,
            rollbackOnFailure: true,
            updateMetadata: true,
          ),
        );
        return true;
      }, showError: showError);
      if (updated == true) {
        ref.read(currentPageLabelProvider.notifier).value = PageLabel.dashboard;
      }
      return updated == true;
    }
    final profile = await globalState.loadingRun(
      tag: LoadingTag.profiles,
      () async {
        return captureError(() => Profile.normal(url: url).update());
      },
      title: currentAppLocalizations.addProfile,
      showError: showError,
    );
    if (profile != null) {
      putProfile(profile);
      ref.read(currentPageLabelProvider.notifier).value = PageLabel.dashboard;
      return true;
    }
    return false;
  }

  void setProfileAndAutoApply(Profile profile) {
    ref.read(profilesProvider.notifier).put(profile);
    if (profile.id == ref.read(currentProfileIdProvider)) {
      ref.read(setupActionProvider.notifier).applyProfileDebounce();
    }
  }

  Future<void> addProfileFormQrCode() async {
    final url = await globalState.safeRun(picker.pickerConfigQRCode);
    if (url == null) return;
    addProfileFormURL(url);
  }

  void reorder(List<Profile> profiles) {
    ref.read(profilesProvider.notifier).reorder(profiles);
  }

  Future<void> clearEffect(int profileId) async {
    final profilePath = await appPath.getProfilePath(profileId.toString());
    final profileFile = File(profilePath);
    final isExists = await profileFile.exists();
    if (isExists) {
      await profileFile.safeDelete(recursive: true);
    }
    final error = await coreController.clearEffect(profileId);
    if (error.isNotEmpty) {
      commonPrint.log(error, logLevel: LogLevel.warning);
    }
  }
}
