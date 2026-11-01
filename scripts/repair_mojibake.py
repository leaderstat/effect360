#!/usr/bin/env python3
# scripts/repair_mojibake.py
#
# Ремонт двойного UTF-8 кодирования (mojibake) в текстовых полях БД.
#
# ПРОБЛЕМА
#   Если SQL-файл передать в контейнер через конвейер PowerShell
#   (`Get-Content file.sql | psql`), байты кириллицы перекодируются по текущей
#   кодовой странице консоли. PostgreSQL затем сохраняет строку, в которой
#   каждый исходный байт UTF-8 стал ОДНИМ символом CP1251, а она сама
#   затем была снова закодирована в UTF-8. В интерфейсе это выглядит как
#   "Р”РµРјРѕ Р—Р°РЅРѕС‚РµР»СЊ" вместо "Демо Заявитель".
#
#   ОБРАТИМОСТЬ
#   Преобразование обратимо: байты исходной строки восстанавливаются из
#   кодовых точек повреждённой строки обратным отображением CP1251.
#
#   БЕЗОПАСНОСТЬ
#   Скрипт трогает ТОЛЬКО строки с `is_demo = true` (синтетические данные).
#   Продуктивные данные не изменяются. Скрипт идемпотентен: повторный
#   запуск на исправленных данных не меняет ни одной строки.
#
# ИСПОЛЬЗОВАНИЕ
#   python scripts/repair_mojibake.py            # dry-run (только отчёт)
#   python scripts/repair_mojibake.py --apply    # применить
#
# Требуется: psql в PATH и переменные окружения PGHOST/PGUSER/PGDATABASE
# (либо переопределите их флагами --host/--user/--database).

import argparse
import os
import subprocess
import sys

# Таблицы и колонки, которые проверяем. Порядок не важен.
#
# Сейчас `is_demo = true` есть только у таблицы `users` — остальные таблицы
# не содержат пометки «синтетические данные», поэтому их текст мы не
# трогаем автоматически (чтобы не повредить продуктивные записи).
TARGETS = [
    ("users", "display_name"),
]


def build_reverse_map():
    """Кодовая точка -> байт CP1251 (обратное отображение)."""
    reverse = {}
    for byte in range(256):
        try:
            char = bytes([byte]).decode("cp1251")
        except UnicodeDecodeError:
            continue
        # Первое вхождение выигрывает: в CP1251 есть дубли (например 0x98/0x99).
        reverse.setdefault(char, byte)
    return reverse


REVERSE_CP1251 = build_reverse_map()


def looks_like_mojibake(text):
    """Признак повреждения: есть символы «Latin-1 Supplement»/«Cyrillic»,
    которые не встречаются в корректных русских именах, и нет обычных
    кириллических букв в ожидаемом виде.

    Эвристика: строка повреждена, если в ней встречаются символы из
    U+00C0..U+00FF или U+0400..U+045F в количестве, нетипичном для
    русских слов, И при этом обратное преобразование даёт валидный UTF-8
    с кириллицей.
    """
    if not text:
        return False
    # Считаем символы, характерные для результата неверной перекодировки.
    suspicious = sum(
        1 for ch in text if "Ѐ" <= ch <= "џ" or "€" <= ch <= "ÿ"
    )
    if suspicious == 0:
        return False
    # Если обратное преобразование даёт строку с кириллицей — это mojibake.
    repaired = repair(text)
    return repaired != text and any("Ѐ" <= ch <= "џ" for ch in repaired)


def repair(text):
    """Восстановить исходные байты строки.

    Каждый символ повреждённой строки сопоставляется с одним байтом CP1251.
    Символы, которых нет в CP1251 (например пробел), кодируются как есть.
    """
    out = bytearray()
    for char in text:
        byte = REVERSE_CP1251.get(char)
        if byte is None:
            out.extend(char.encode("utf-8"))
        else:
            out.append(byte)
    try:
        return bytes(out).decode("utf-8")
    except UnicodeDecodeError:
        return text


def psql(sql, host, user, database, quiet=True):
    """Выполнить SQL и вернуть stdout.

    Скрипт работает и на Windows, где `psql` может отсутствовать, поэтому
    поддерживается запуск через `docker exec` в контейнер PostgreSQL.
    Переменная окружения E360_PG_CONTAINER задаёт имя контейнера; если она
    не задана, используется локальный `psql`.
    """
    container = os.environ.get("E360_PG_CONTAINER", "").strip()
    if container:
        cmd = [
            "docker",
            "exec",
            "-i",
            container,
            "psql",
            "-v",
            "ON_ERROR_STOP=1",
            "-U",
            user,
            "-d",
            database,
            "-t",
            "-A",
            "-F",
            "\x1f",
            "-c",
            sql,
        ]
    else:
        cmd = [
            "psql",
            "-v",
            "ON_ERROR_STOP=1",
            "-h",
            host,
            "-U",
            user,
            "-d",
            database,
            "-t",
            "-A",
            "-F",
            "\x1f",
            "-c",
            sql,
        ]
    env = dict(os.environ, PGPASSWORD=os.environ.get("PGPASSWORD", ""))
    # Вывод psql — это UTF-8 (кириллица). Консоль Windows по умолчанию
    # отдаёт cp1251/cp866, и subprocess.decode() падает на байтах 0x98/0x99.
    # Поэтому кодировку задаём явно.
    result = subprocess.run(
        cmd,
        capture_output=True,
        env=env,
        encoding="utf-8",
        errors="replace",
    )
    if result.returncode != 0:
        raise RuntimeError(f"psql failed: {result.stderr.strip()}")
    if not quiet:
        print(result.stdout)
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="применить изменения")
    parser.add_argument("--host", default=os.environ.get("PGHOST", "localhost"))
    parser.add_argument("--user", default=os.environ.get("PGUSER", "effectivnost360"))
    parser.add_argument("--database", default=os.environ.get("PGDATABASE", "effectivnost360"))
    args = parser.parse_args()

    total_changed = 0

    for table, column in TARGETS:
        # Читаем только DEMO-строки: id + текст.
        sql = (
            f"SELECT id, {column} FROM {table} "
            "WHERE is_demo = true AND "
            f"{column} IS NOT NULL AND {column} <> '';"
        )
        try:
            rows = psql(sql, args.host, args.user, args.database)
        except RuntimeError as exc:
            print(f"SKIP {table}.{column}: {exc}", file=sys.stderr)
            continue

        if not rows.strip():
            print(f"{table}.{column}: no demo rows")
            continue

        for line in rows.splitlines():
            if "\x1f" not in line:
                continue
            row_id, text = line.split("\x1f", 1)
            if not looks_like_mojibake(text):
                continue
            fixed = repair(text)
            total_changed += 1
            print(f"{table}.{column} id={row_id}")
            print(f"  before: {text.encode('unicode_escape').decode()}")
            print(f"  after : {fixed.encode('unicode_escape').decode()}")

            if args.apply:
                # Значение вставляем как параметр SQL (psql -v), чтобы
                # кодировка не зависела от кодовой страницы консоли.
                escaped = fixed.replace("'", "''")
                update = f"UPDATE {table} SET {column} = '{escaped}' WHERE id = '{row_id}';"
                psql(update, args.host, args.user, args.database)
                print("  applied")

    print()
    if total_changed == 0:
        print("Nothing to repair.")
    elif args.apply:
        print(f"Repaired {total_changed} row(s).")
    else:
        print(f"Would repair {total_changed} row(s). Re-run with --apply.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
