#!/usr/bin/env bash

set -u

base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log_dir="$base_dir/log"
backup_dir="$base_dir/backup"
img_file="$base_dir/ext4_volume.img"
script1="$base_dir/script1.sh"

total_tests=0
passed_tests=0

echo "Запуск автоматического тестирования."

# вопрос пользователю

while true; do
	echo "Введите лимит для папки (600M, 1G, 2G)."
	read -p "Минимум 512M (0.5G): " user_size

	if [[ "$user_size" =~ ^([0-9]+)[Gg]$ ]]; then 
		size_mb=$(( BASH_REMATCH[1] * 1024 ))
	elif [[ "$user_size" =~ ^([0-9]+)[Mm]$ ]]; then
		size_mb=$(( BASH_REMATCH[1] ))
	else
		echo "Неверный формат! Используйте G или M. (600M или 1G, например)."
		continue
	fi

	if (( size_mb < 512 )); then
		echo "Ошибка! Размер папки должен быть не менее 512M (0.5G) для корректных тестов."
	else
		volume_size="$user_size"
		echo "Выбран жесткий лимит папки: $volume_size."
		break
	fi
done

# проверка зависимостей fuse2fs


if ! command -v fuse2fs >/dev/null 2>&1; then
	echo "Ошибка: fuse2fs не установлен. Установите: sudo apt install fuse2fs"
	exit 2
fi
if [[ ! -e /dev/fuse ]]; then
	echo "Ошибка: /dev/fuse недоступен. Загрузите модуль fuse."
	exit 2
fi


# подготовка окружения

cleanup_environment() {
	if mountpoint -q "$log_dir" 2>/dev/null; then
		fusermount -u "$log_dir" 2>/dev/null
	fi
	rm -f "$img_file"
	rm -rf "$log_dir" "$backup_dir"
	mkdir -p "$log_dir" "$backup_dir"
}

set_space() {
	truncate -s "$volume_size" "$img_file"
	mkfs.ext4 -q -m 0 -O ^has_journal -E "root_owner=$(id -u):$(id -g)" "$img_file"
	if ! fuse2fs "$img_file" "$log_dir"; then
		echo "Ошибка! Не удалось смонтировать $img_file в $log_dir через fuse2fs."
		exit 3
	fi
	echo "Смонтирован ext4 образ $volume_size в $log_dir через fuse2fs."
}

create_log() {
	local name="$1"
	local size_mb="$2"
	local age_days="$3"

	dd if=/dev/zero of="$log_dir/$name" bs=1M count="$size_mb" status=none
	touch -d "$age_days days ago" "$log_dir/$name"
}

perc_to_mb() {
	local perc="$1"
	local total_mb="$size_mb"
	local res=$(( total_mb * perc / 100 ))
	if (( res <= 0 )); then
		res=1
	fi
	echo "$res"
}

print_result() {
	local test_name="$1"
	local status="$2"
	total_tests=$((total_tests + 1))
	if [[ "$status" -eq 1 ]]; then
		echo -e "Успех, $test_name Пройден"
		passed_tests=$((passed_tests + 1))
	else
		echo -e "Провал, $test_name Завален"
	fi
}

if [[ ! -f "$script1" ]]; then
	echo -e "Ошибка! Скрипт 1 (script1.sh) не найден в текущей директории."
	exit 1
fi
chmod +x "$script1"


# тест 1

echo "==========ЗАПУСК ТЕСТА 1=========="

cleanup_environment
set_space

create_log "1.log" "$(perc_to_mb 30)" 5
create_log "2.log" "$(perc_to_mb 29)" 1

"$script1" "$log_dir" 70
status_test1=$?

if (( status_test1 != 0 )); then
	echo "script1.sh упал с кодом $status_test1"
	print_result "Тест 1" 0
elif [ -f "$log_dir/1.log" ] && [ -z "$(ls -A "$backup_dir")" ]; then
	print_result "Тест 1" 1
else
	print_result "Тест 1" 0
fi


# тест 2

echo "==========ЗАПУСК ТЕСТА 2=========="

cleanup_environment
set_space

create_log "1.log" "$(perc_to_mb 10)" 5
create_log "2.log" "$(perc_to_mb 20)" 1
create_log "3.log" "$(perc_to_mb 40)" 1

"$script1" "$log_dir" 50
status_test2=$?

if (( status_test2 != 0 )); then
	echo "script1.sh упал с кодом $status_test2"
	print_result "Тест 2" 0
elif [ ! -f "$log_dir/1.log" ] && [ -f "$log_dir/3.log" ] && [ -n "$(ls -A "$backup_dir")" ]; then
	print_result "Тест 2" 1
else
	print_result "Тест 2" 0
fi

# тест 3

echo "==========ЗАПУСК ТЕСТА 3=========="

cleanup_environment
set_space

create_log "1.log" "$(perc_to_mb 29)" 4
create_log "2.log" "$(perc_to_mb 29)" 3
create_log "3.log" "$(perc_to_mb 29)" 2

"$script1" "$log_dir" 10
status_test3=$?

if (( status_test3 != 0 )); then
	echo "script1.sh упал с кодом $status_test3"
	print_result "Тест 3" 0
elif [ -z "$(find "$log_dir" -maxdepth 1 -type f -print -quit)" ] && [ -n "$(ls -A "$backup_dir")" ]; then
        print_result "Тест 3" 1
else
        print_result "Тест 3" 0
fi

# тест 4

echo "==========ЗАПУСК ТЕСТА 4=========="

cleanup_environment
set_space

echo "=== Сценарий: без аргументов. ==="
"$script1";	status_noargs=$?
echo "=== Сценарий: проценты в 'abc'. ==="
"$script1" "$log_dir" abc;	status_nan=$?
echo "=== Сценарий: отрицательный процент. ==="
"$script1" "$log_dir" -1;	status_neg=$?
echo "=== Сценарий: процент больше 100. ==="
"$script1" "$log_dir" 150;	status_big=$?
echo "=== Сценарий: несуществующая папка. ==="
"$script1" "/ne/suchestv/papka/put" 70;	status_bad_dir=$?

if (( status_noargs != 0 && status_nan != 0 && status_neg != 0 && status_big != 0 && status_bad_dir != 0)); then
    print_result "Тест 4" 1
else
    print_result "Тест 4" 0
fi

# тест 5

echo "==========ЗАПУСК ТЕСТА 5=========="

cleanup_environment
set_space

create_log "1.log" "$(perc_to_mb 25)" 5
create_log "2.log" "$(perc_to_mb 26)" 1

export LAB1_MAX_COMPRESSION=1

"$script1" "$log_dir" 50
status_test5=$?

lzma=$(find "$backup_dir" -type f \( -name "*.lzma" -o -name "*.xz" \) 2>/dev/null)

if (( status_test5 != 0)); then
	echo "script1.sh упал с кодом $status_test5"
	print_result "Тест 5" 0
elif [ -n "$lzma" ]; then
        print_result "Тест 5" 1
else
        print_result "Тест 5" 0
fi

unset LAB1_MAX_COMPRESSION

# Итоги

cleanup_environment
echo "==========РЕЗУЛЬТАТЫ ТЕСТИРОВАНИЯ: Успешно $passed_tests из $total_tests=========="

if [ "$passed_tests" == "$total_tests" ]; then
	echo "Все тесты успешно пройдены!"
	exit 0
else
	echo "Есть проваленные тесты!"
	exit 1
fi
