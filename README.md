# Glassy Record

Приложение для одновременной записи экрана и Face Cam с наложением очков **Monokol MK295** в реальном времени.

## Структура проекта

```
GlassyRecord/
├── App/                          # Точка входа, Coordinator
│   ├── GlassyRecordApp.swift     # @main, NavigationStack, SwiftData container
│   └── AppCoordinator.swift      # Маршрутизация + SettingsStore (Combine)
├── Core/
│   ├── Models/AppModels.swift    # Доменные типы, ошибки, маршруты
│   └── Persistence/              # SwiftData: настройки и метаданные записей
├── Services/
│   ├── CameraService.swift       # AVFoundation — фронтальная камера
│   ├── ScreenRecorderService.swift # ReplayKit + AVAssetWriter
│   ├── AudioService.swift        # Микрофон, уровни, микширование
│   ├── RenderService.swift       # Metal-композиция и CI-фильтры
│   ├── GlassesOverlayService.swift # ARKit/Vision + SceneKit — очки MK295
│   └── ExportService.swift       # H.264/HEVC, Photos
├── Features/
│   ├── Home/                     # Главный экран, быстрые настройки
│   ├── Recording/                # Оверлей записи, ViewModel
│   ├── Editor/                   # Timeline, обрезка, экспорт
│   └── Settings/                 # Группированные настройки HIG
├── UI/
│   ├── Theme/GlassyTheme.swift   # Liquid Glass, анимации, c40-цвета
│   └── Components/               # Карточки, панель управления, PencilKit
└── Resources/
    ├── Info.plist                # Разрешения камера/микрофон/экран/галерея
    ├── Assets.xcassets           # AccentColor, GlassesRed/Blue
    └── GlassyRecord.entitlements # Multitasking camera access
```

## Архитектурные решения

### ARKit vs Vision для очков

| Подход | Плюсы | Минусы |
|--------|-------|--------|
| **ARKit** (выбран как primary) | Точная 3D-геометрия лица, blend shapes, стабильная привязка | Только TrueDepth (iPhone X+) |
| **Vision** (fallback) | Работает на всех устройствах iOS 18+ | Менее точное позиционирование |
| RealityKit + USDZ | Простая загрузка моделей | Сложнее композиция с CVPixelBuffer |

`GlassesOverlayService` использует **ARKit + ARSCNFaceGeometry** для привязки и **процедурную SceneKit-модель** Monokol MK295 (кубическая оправа, глянцевый PBR-ацетат). USDZ-файлы можно добавить в `Resources/Models/` и загружать через `SCNScene(named:)`.

### Композиция видео

ReplayKit захватывает экран → `RenderService` (Metal blit) накладывает Face Cam → `GlassesOverlayService` рендерит 3D-очки в pixel buffer.

### Хранение данных

**SwiftData** для настроек и метаданных записей (легче Core Data для этого объёма).

## Требования

- iOS 18.0+ (оптимизировано под iOS 26+ / Liquid Glass)
- Xcode 16+
- Устройство с камерой; TrueDepth — для AR-трекинга очков

## Сборка

```bash
cd ~/Projects/GlassyRecord
xcodegen generate
open GlassyRecord.xcodeproj
```

Укажите `DEVELOPMENT_TEAM` в `project.yml` или в Xcode перед запуском на устройстве.

## Разрешения (Info.plist)

- `NSCameraUsageDescription` — Face Cam и очки
- `NSMicrophoneUsageDescription` — запись голоса
- `NSPhotoLibraryAddUsageDescription` — экспорт в галерею
- `UIBackgroundModes`: audio, processing — фоновая запись

## Тесты

```bash
xcodebuild test -scheme GlassyRecord -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

- **Unit**: модели, GlassesOverlayService, SettingsStore
- **UI**: главный экран, настройки, очки

## App Store

- `ITSAppUsesNonExemptEncryption = false`
- ReplayKit требует согласия пользователя на запись экрана (системный диалог)
- Фоновая запись — с локальным уведомлением (добавить в `RecordingViewModel` перед релизом)
