#!/usr/bin/env bash
# Simple script to download videos from GetCourse.ru
# on Linux/*BSD
# Dependencies: bash, coreutils, curl, grep, parallel, pv

set -eu
set +f
set -o pipefail

if [ ! -f "$0" ]; then
    a0="$0"
else
    a0="bash $0"
fi

_echo_help() {
    echo "
Первым аргументом должна быть ссылка на плей-лист, найденная в исходном коде страницы сайта GetCourse.
Пример: <video id=\"vgc-player_html5_api\" data-master=\"нужная ссылка\" ... />.
Вторым аргументом должен быть путь к файлу для сохранения скачанного видео, рекомендуемое расширение — ts.
Пример: \"Как скачать видео с GetCourse.ts\"
Скопируйте ссылку и запустите скрипт, например, так:
$a0 \"эта_ссылка\" \"Как скачать видео с GetCourse.ts\"
Инструкция с графическими иллюстрациями здесь: https://github.com/mikhailnov/getcourse-video-downloader
О проблемах в работе сообщайте сюда: https://github.com/mikhailnov/getcourse-video-downloader/issues
"
}

tmpdir="$(umask 077 && mktemp -d)"
export TMPDIR="$tmpdir"
trap 'rm -fr "$tmpdir"' EXIT

# Check for pv
if ! command -v pv >/dev/null 2>&1; then
    echo "Ошибка: 'pv' не установлен. Установите выполнив:"
    echo "Ubuntu/Debian: sudo apt-get install pv"
    echo "macOS: brew install pv"
    exit 1
fi

if [ -z "${1:-}" ] || [ -z "${2:-}" ] || [ -n "${3:-}" ]; then
    _echo_help
    exit 1
fi

URL="$1"
result_file="$2"
touch "$result_file"

# Default to 4 threads, but allow overriding with the PP environment variable
PP=${PP:-4}

main_playlist="$(mktemp)"
curl -L --output "$main_playlist" "$URL"
second_playlist="$(mktemp)"

# Check for direct video segment URLs
if grep -qE '^https?:\/\/.*\.(ts|bin)' "$main_playlist" 2>/dev/null; then
    cp "$main_playlist" "$second_playlist"
else
    tail="$(tail -n1 "$main_playlist")"
    if ! [[ "$tail" =~ ^https?:// ]]; then
        echo "В содержимом заданной ссылки нет прямых ссылок на файлы *.bin (*.ts) (первый вариант),"
        echo "также последняя строка в ней не содержит ссылки на другой плей-лист (второй вариант)."
        echo "Либо указана неправильная ссылка, либо GetCourse изменил алгоритмы."
        echo "Если уверены, что дело в изменившихся алгоритмах GetCourse, опишите проблему здесь:"
        echo "https://github.com/mikhailnov/getcourse-video-downloader/issues (на русском)."
        exit 1
    fi
    curl -L --output "$second_playlist" "$tail"
fi

# Export variables for use in parallel
export tmpdir

# Download segments in parallel using GNU parallel
total_segments=$(grep -c '^http' "$second_playlist")
current_segment=0

echo "Скачиваю $total_segments сегментов..."
cat "$second_playlist" | grep '^http' | parallel --bar -j "6" --no-notice \
    'curl -s --retry 12 -L --output "${TMPDIR}/$(printf "%05d" {#}).ts" {}'

echo "Соединяю сегменты..."
cat "$tmpdir"/*.ts | pv -s $(du -cb "$tmpdir"/*.ts | tail -n1 | cut -f1) > "$result_file"
echo "Скачивание завершено. Результат:
$result_file"
