# JokerShift 🃏

Мобильная версия карточной игры на Godot 4.7.2.

## Как собрать APK

1. Скачай подготовленный архив **JokerShiftProject.zip** из чата.
2. Зайди в [загрузку файлов](https://github.com/fF0GGY824/JokerShift/upload/main).
3. Загрузи **JokerShiftProject.zip** как один файл в корень репозитория (не распаковывай) и нажми **Commit changes**.
4. Автоматически запустится [Build JokerShift APK](https://github.com/fF0GGY824/JokerShift/actions/workflows/android.yml).
5. Открой успешный запуск, скачай **JokerShift-Android-APK** из раздела **Artifacts**. В скачанном архиве будет `JokerShift.apk`.

Сборка создает тестовый APK для ARM32 и ARM64, с вертикальной ориентацией (portrait) и адаптивным интерфейсом. Реальный мультиплеер ещё в разработке.

> Проектные исходники пока поставляются одним ZIP: GitHub Actions распаковывает его автоматически перед сборкой. Этот README и workflow уже добавлены в репозиторий.