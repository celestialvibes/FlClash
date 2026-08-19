import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/views/views.dart';
import 'package:flutter/material.dart';

class Navigation {
  static Navigation? _instance;

  List<NavigationItem> getItems() {
    return [
      NavigationItem(
        keep: false,
        icon: const Icon(Icons.home_outlined),
        label: PageLabel.dashboard,
        builder: (_) =>
            const LoomHomeView(key: GlobalObjectKey(PageLabel.dashboard)),
      ),
      NavigationItem(
        icon: const Icon(Icons.route_outlined),
        label: PageLabel.proxies,
        builder: (_) =>
            const LoomServersView(key: GlobalObjectKey(PageLabel.proxies)),
      ),
      NavigationItem(
        icon: const Icon(Icons.bar_chart_outlined),
        label: PageLabel.statistics,
        builder: (_) => const LoomStatisticsView(
          key: GlobalObjectKey(PageLabel.statistics),
        ),
      ),
    ];
  }

  String getLabel(PageLabel label) => switch (label) {
    PageLabel.dashboard => 'Главная',
    PageLabel.proxies => 'Маршруты',
    PageLabel.statistics => 'Статистика',
    _ => label.name,
  };

  Navigation._internal();

  factory Navigation() {
    _instance ??= Navigation._internal();
    return _instance!;
  }
}

final navigation = Navigation();
