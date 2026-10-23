#!/usr/bin/env bash
set -euo pipefail

#Значения по умолчанию
THRESHOLD=70

#Аргументы
if [ $# -lt 1 ]; then
    echo "Использование: $0 <путь_к_папке> [порог_в_процентах]" >&2
    echo "Пример:        $0 /var/log 70" >&2
    echo "" >&2
    echo "Переменные окружения:" >&2
    echo "  BACKUP_DIR           — куда складывать архивы (по умолчанию /backup)" >&2
    echo "  LAB1_MAX_COMPRESSION — если =1, использовать lzma" >&2
    exit 1
fi

LOG_DIR="$1"
BACKUP_DIR="${BACKUP_DIR:-$(dirname "$LOG_DIR")/backup}"

if [ $# -ge 2 ]; then
    THRESHOLD="$2"
fi

#Валидация
if [ ! -d "$LOG_DIR" ]; then
    echo "Ошибка: '$LOG_DIR' не существует или не является директорией." >&2
    exit 1
fi

if ! [[ "$THRESHOLD" =~ ^[0-9]+$ ]]; then
    echo "Ошибка: порог должен быть целым неотрицательным числом, получено: '$THRESHOLD'" >&2
    exit 1
fi

if [ "$THRESHOLD" -lt 0 ] || [ "$THRESHOLD" -gt 100 ]; then
    echo "Ошибка: порог должен быть в диапазоне 0..100, получено: $THRESHOLD" >&2
    exit 1
fi

if [ ! -d "$BACKUP_DIR" ]; then
    if ! mkdir -p "$BACKUP_DIR"; then
        echo "Ошибка: не удалось создать папку для бэкапов '$BACKUP_DIR'." >&2
        exit 1
    fi
    echo "Создана папка для бэкапов: $BACKUP_DIR"
fi

#Функции для расчёта заполнения
get_usage_percent() {
    df -P "$1" | awk 'NR==2 {gsub(/%/,"",$5); print $5}'
}

get_fs_size_bytes() {
    df -P -B1 "$1" | awk 'NR==2 {print $2}'
}

#Цикл
echo "Проверяю заполнение ФС для '$LOG_DIR' (порог: ${THRESHOLD}%)..."

while true; do
    current_usage=$(get_usage_percent "$LOG_DIR")
    echo "Текущее заполнение: ${current_usage}%"

    if [ "$current_usage" -le "$THRESHOLD" ]; then
        echo "Заполнение в норме, архивация не требуется."
        break
    fi

    fs_size_bytes=$(get_fs_size_bytes "$LOG_DIR")
    diff_percent=$(( current_usage - THRESHOLD ))
    needed_bytes=$(awk -v d="$diff_percent" -v s="$fs_size_bytes" 'BEGIN {printf "%.0f", (d/100)*s}')

    echo "Порог превышен на ${diff_percent}% — нужно освободить ~${needed_bytes} байт."

    mapfile -d '' -t entries < <(find "$LOG_DIR" -maxdepth 1 -type f -printf '%T@ %p\0' | sort -z -n)

    if [ ${#entries[@]} -eq 0 ]; then
        echo "В папке '$LOG_DIR' нет файлов для архивации."
        break
    fi

    total_size=0
    files_to_archive=()

    for entry in "${entries[@]}"; do
        path="${entry#* }"
        size=$(stat -c %s "$path")

        files_to_archive+=("$path")
        total_size=$(( total_size + size ))

        if [ "$total_size" -ge "$needed_bytes" ]; then
            break
        fi
    done

    if [ ${#files_to_archive[@]} -eq 0 ]; then
        echo "Не удалось подобрать файлы для архивации."
        break
    fi

    echo "Отобрано ${#files_to_archive[@]} файлов, суммарно ${total_size} байт."

    #Архивация
    timestamp=$(date +%Y%m%d_%H%M%S)

    if [ "${LAB1_MAX_COMPRESSION:-0}" = "1" ]; then
        archive_name="archive_${timestamp}.tar.xz"
        tar_flag="-cJf"
        echo "Использую максимальное сжатие (lzma/xz)."
    else
        archive_name="archive_${timestamp}.tar.gz"
        tar_flag="-czf"
    fi

    archive_path="$BACKUP_DIR/$archive_name"

    file_names=()
    for f in "${files_to_archive[@]}"; do
        file_names+=("$(basename "$f")")
    done

    echo "Архивирую в '$archive_path'..."
    tar $tar_flag "$archive_path" -C "$LOG_DIR" -- "${file_names[@]}"

    #Удаление заархивированных
    echo "Удаляю заархивированные файлы из '$LOG_DIR'..."
    for f in "${files_to_archive[@]}"; do
        rm -f "$f"
    done

    echo "Итерация завершена, проверяю заполнение снова..."
    echo ""
done

echo "Готово."
