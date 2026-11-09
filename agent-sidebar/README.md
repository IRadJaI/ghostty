# Agent sidebar для Ghostty (форк, PoC)

Ветка `agent-sidebar` = Ghostty **v1.4.0** + боковая панель с вертикальными
вкладками и статусами агентов, по мотивам сайдбара Intelligent Terminal 0.3.

> **Статус: код написан вслепую.** Он создан в Linux-контейнере без Xcode и
> ни разу не компилировался. Синтаксис Swift проверен парсером, типы — нет.
> Хук-скрипт и установщик хуков проверены запуском. При первой сборке на Mac
> ждите ошибок компиляции; вероятные места перечислены ниже.

## Что должно получиться

Слева в каждом окне терминала панель «Tabs»:

- вертикальный список вкладок окна: иконка, заголовок, под ним метаданные;
- иконка агента (✳ у Claude Code), во время работы агента вместо неё крутилка;
- статус агента: `Working…` / `Needs you` (с текстом запроса) / `Done` / `Idle`;
- оранжевая точка у вкладки, которая ждёт вас или звенит (bell);
- текущая папка, git-репозиторий, ветка, число изменённых файлов;
- меню настроек (иконка с ползунками): «Agents only», «Recent agent sessions»,
  набор метаданных, «Hide native tab bar»;
- поиск по вкладкам, кнопка «+» (новая вкладка), крестик при наведении;
- раздел «Recent agent sessions»: последние сессии Claude Code из
  `~/.claude/projects`, клик открывает новую вкладку с `claude --resume <id>`;
- кнопка сворачивания панели в узкую полоску.

## Сборка на Mac

Нужны Xcode 26 (с macOS 26 SDK и Metal Toolchain) и Zig 0.17.x — это
требования самого Ghostty 1.4, см. `HACKING.md`.

```bash
git clone -b agent-sidebar https://github.com/IRadJaI/ghostty.git
cd ghostty

# 1. Ядро (GhosttyKit). Долго только в первый раз.
zig build -Demit-macos-app=false

# 2. Приложение. Debug-сборка имеет отдельный bundle id
#    (com.mitchellh.ghostty.debug) и не мешает установленному Ghostty.
xcodebuild -project macos/Ghostty.xcodeproj -scheme Ghostty \
  -configuration Debug SYMROOT="$PWD/macos/build" build

open macos/build/Debug/Ghostty.app
```

Debug-сборка медленная и показывает жёлтую плашку — это штатное поведение
Ghostty. Для повседневного использования собирайте `-configuration
ReleaseLocal`; у неё bundle id обычного Ghostty, поэтому официальный Ghostty
перед запуском надо закрыть.

Если Xcode ругается на код сайдбара, пришлите вывод ошибок целиком: правки
там точечные.

## Статусы Claude Code (хуки)

Без хуков сайдбар только узнаёт агента (по процессу в терминале и по
заголовку). Статусы «работает / ждёт вас / готово» приходят из хуков:

```bash
agent-sidebar/install-claude-hooks.py            # установить
agent-sidebar/install-claude-hooks.py --print    # показать, что будет записано
agent-sidebar/install-claude-hooks.py --remove   # убрать
```

Установщик дописывает шесть хуков в `~/.claude/settings.json` (существующие
хуки не трогает, перед изменением делает резервную копию) и копирует скрипт в
`~/.ghostty-agents/bin/ghostty-agent-hook`. После установки перезапустите
открытые сессии Claude Code.

Как это работает: Claude Code на событиях (`UserPromptSubmit`, `PreToolUse`,
`Notification`, `Stop`, `SessionStart`, `SessionEnd`) запускает скрипт. Тот
находит tty терминала и пишет `~/.ghostty-agents/status/<tty>.json`. Сайдбар
раз в секунду читает эти файлы и сопоставляет их с вкладками по tty. Наружу
ничего не отправляется.

## Что изменено в коде Ghostty

| Файл | Что |
|---|---|
| `macos/Sources/Features/Terminal/TerminalController.swift` | **единственная правка upstream**: +4/−1 строка, корневой вид окна обёрнут в `AgentSidebarContainer` |
| `macos/Sources/Features/Agent Sidebar/AgentSidebarTypes.swift` | новый: типы и разбор данных (хуки, git, сессии), только Foundation |
| `macos/Sources/Features/Agent Sidebar/AgentSidebarModel.swift` | новый: общий на приложение снимок вкладок, определение агентов, действия |
| `macos/Sources/Features/Agent Sidebar/AgentSidebarView.swift` | новый: интерфейс на SwiftUI |
| `agent-sidebar/` | хук-скрипт, установщик хуков, этот README |

Файл проекта Xcode не менялся: папка `Sources` подключена как синхронизируемая,
новые файлы попадают в сборку сами. Ядро на Zig не тронуто. Быстрый терминал
(Quick Terminal) сайдбар не получает.

## Где вероятнее всего сломается

1. **`proc_name` в `AgentSidebarModel.processName`.** Если `import Darwin` его
   не видит, функцию можно временно заменить на `return nil`: останется
   определение агента по хукам и заголовку.
2. **Скрытие родной полосы вкладок** (`applyNativeTabBarVisibility`). Это
   самое хрупкое место: полоса вкладок ищется по приватному имени класса
   `NSTabBar`. Если полоса не скрывается или ведёт себя странно, особенно при
   `macos-titlebar-style = tabs`, выключите «Hide native tab bar» в меню
   сайдбара.
3. **Изоляция акторов.** Модель помечена `@MainActor`, фоновая работа (git,
   чтение сессий) уходит в `DispatchQueue`. Проект собирается в режиме Swift 5,
   так что это должны быть предупреждения, а не ошибки.
4. **Размер нового окна.** Ширина сайдбара (240 pt) добавляется к содержимому,
   поэтому окно с заданным `window-width` получит терминал уже на эти 240 pt.
5. **Каждая вкладка — отдельное окно macOS** со своей копией сайдбара. Данные
   общие, но при переключении вкладок возможны мелкие визуальные артефакты
   (например, сбрасывается прокрутка списка).

## Чего пока нет

- изменения ширины панели мышью (ширина хранится в настройке
  `AgentSidebar.width`, 180–480);
- горячих клавиш и пунктов в главном меню;
- перетаскивания вкладок в сайдбаре, закрепления, превью содержимого;
- статусов для агентов, кроме Claude Code (остальные только распознаются);
- тестов.

## Синхронизация с upstream

Патч задевает одну строку upstream-кода, поэтому переход на следующую версию —
это `git rebase` ветки на новый тег. Конфликт возможен только в месте создания
`TerminalViewContainer` в `TerminalController.swift`.
