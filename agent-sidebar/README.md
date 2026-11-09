# Agent sidebar для Ghostty (форк, PoC)

Ветка `agent-sidebar` = Ghostty **v1.4.0** + боковая панель с вертикальными
вкладками и статусами агентов, по мотивам сайдбара Intelligent Terminal 0.3.

> **Статус: собирается, но ни разу не запускался.** Код написан в
> Linux-контейнере без Mac. Сборка проходит на macOS-машине GitHub Actions
> (workflow `agent-sidebar`, Xcode 26), то есть код компилируется. Как сайдбар
> выглядит и ведёт себя, никто ещё не видел. Хук-скрипт и установщик хуков
> проверены запуском. Места, где вероятнее всего проявятся проблемы при
> работе, перечислены ниже.

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

## Готовая сборка из GitHub Actions

Каждый пуш в ветку собирает Debug-приложение. Скачать его можно со страницы
запуска workflow `agent-sidebar` (раздел Artifacts,
`Ghostty-agent-sidebar-debug`): <https://github.com/IRadJaI/ghostty/actions/workflows/agent-sidebar.yml>

Приложение подписано только ad-hoc подписью, без сертификата разработчика,
поэтому после распаковки снимите карантин:

```bash
unzip Ghostty-agent-sidebar-debug.zip      # внутри ещё один zip с Ghostty.app
xattr -dr com.apple.quarantine Ghostty.app
open Ghostty.app
```

Это Debug-сборка: у неё свой bundle id (`com.mitchellh.ghostty.debug`), она
не мешает установленному Ghostty, работает медленнее и показывает жёлтую
плашку.

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

## Что проверить глазами в первую очередь

1. **Скрытие родной полосы вкладок** (`applyNativeTabBarVisibility`). Это
   самое хрупкое место: полоса вкладок — приватная часть AppKit. Если она не
   скрывается или ведёт себя странно, особенно при
   `macos-titlebar-style = tabs`, выключите «Hide native tab bar» в меню
   сайдбара.
2. **Переключение вкладок.** Каждая вкладка — отдельное окно macOS со своей
   копией сайдбара. Данные общие, но возможны мелкие визуальные артефакты
   (например, сбрасывается прокрутка списка).
3. **Полупрозрачный фон.** Используется системный материал боковой панели
   (`NSVisualEffectView`, `.sidebar`, behind-window). Как он сочетается с
   вашей темой и прозрачностью окна Ghostty, нужно смотреть.
4. **Размер нового окна.** Ширина сайдбара добавляется к ширине окна, чтобы
   терминал сохранял `window-width`. Для разделённой панели, вытащенной в
   новое окно, это не учтено.
5. **Распознавание агента по процессу** (`proc_name`). Если Claude Code
   запущен через `node`, без хуков он распознаётся только по заголовку «✳».

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
