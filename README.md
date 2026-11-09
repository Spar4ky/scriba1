# Skryba – nagrywanie i transkrypcja wykładów (iPhone i iPad)

Nagrywasz wykład → po zatrzymaniu Skryba od razu robi transkrypcję → jednym przyciskiem
kopiujesz cały tekst. Możesz też udostępnić nagranie z Dyktafonu prosto do Skryby.

Wersja 1.2: transkrypcja trwa dalej, gdy przejdziesz do innej aplikacji albo zablokujesz
ekran; nagrywanie w tle ma pierwszeństwo. (1.1: pełna wersja na iPada, udostępnianie
z Dyktafonu, postęp przygotowania modelu, dziennik diagnostyczny.)

## Co potrafi

- **Nagrywanie** z wykresem głośności, pauzą i nazwą nagrania. Działa przy zablokowanym
  ekranie (nawet kilka godzin) i wznawia się samo po rozmowie telefonicznej.
- **Transkrypcja od razu po zatrzymaniu** (Whisper na urządzeniu, bez internetu),
  z podglądem tekstu na żywo i paskiem postępu.
- **„Kopiuj całość”** – cały tekst trafia do schowka (na iPadzie z klawiaturą: ⌘⇧C).
- **Udostępnianie z Dyktafonu**: Dyktafon → nagranie → Udostępnij → **Skryba**.
- **Folder „Skryba” w aplikacji Pliki**: każde nagranie zapisane w tym folderze Skryba sama
  doda i przepisze przy otwarciu.
- **iPad**: lista nagrań obok transkrypcji, dowolne okno i orientacja, skróty klawiszowe
  (⌘R nagraj, ⌘O importuj, ⌘, ustawienia, ⌘P pauza, ⌘⏎ zakończ nagrywanie).
- Odtwarzacz (dotknij czasu przy akapicie), edycja tekstu, eksport `.txt`, wyszukiwarka,
  ponowna transkrypcja w innym języku, wznawianie przerwanej transkrypcji.

## Instalacja bez Maca (GitHub + Sideloadly na Windowsie)

1. Wgraj **całą zawartość** tego folderu do repozytorium na GitHubie (razem z ukrytym
   folderem `.github`). Przy aktualizacji wgraj pliki ponownie – nadpiszą stare.
2. Zakładka **Actions** → „Zbuduj IPA” (ruszy samo po wgraniu albo **Run workflow**).
   Po ok. 15–20 minutach pobierz artefakt **Skryba-ipa** i rozpakuj go. W środku są dwa pliki:
   - **`Skryba.ipa`** – właściwy (z uprawnieniem App Group dla udostępniania z Dyktafonu),
   - `Skryba-zapasowa-bez-AppGroup.ipa` – tylko gdyby Sideloadly pokazał błąd przy pierwszym.
3. **Sideloadly** → przeciągnij `Skryba.ipa`, wpisz Apple ID → **Start**. Aktualizacja nie
   kasuje nagrań – nie usuwaj wcześniej starej Skryby.
4. Na urządzeniu: **Tryb dewelopera** (Ustawienia → Prywatność i ochrona) oraz
   Ustawienia → Ogólne → VPN i urządzenia → zaufaj swojemu Apple ID.

> Z darmowym Apple ID aplikacja działa **7 dni** – potem powtórz krok 3 (nagrania zostają).

## Instalacja z Maca (Xcode 26+)

1. Otwórz `Skryba.xcodeproj`, poczekaj na pobranie pakietu WhisperKit.
2. Xcode → Settings → Accounts → dodaj Apple ID.
3. Target **Skryba** i **SkrybaShare** → Signing & Capabilities → **Team**: Twoje konto.
4. Wybierz iPhone’a lub iPada na górnym pasku i naciśnij ▶︎.

Jeśli Xcode zgłosi zajęty identyfikator, zmień `APP_BUNDLE_ID` w `Config/Signing.xcconfig`.

## Pierwsza transkrypcja – przygotowanie modelu

Whisper działa w całości na urządzeniu. Za pierwszym razem:

1. **Pobiera model** (Dokładny ok. 630 MB, Szybki ok. 250 MB) – najlepiej przez Wi-Fi.
2. **Przygotowuje go pod procesor** (Core ML) – jednorazowo, zwykle 1–5 minut, model Dokładny
   czasem dłużej. Na karcie transkrypcji widać licznik czasu. Jeśli trwa to zbyt długo,
   pojawi się przycisk **„Użyj modelu Szybki”**.

Kolejne transkrypcje ruszają od razu. Model możesz też pobrać i przygotować wcześniej:
Ustawienia → Whisper → **Pobierz i przygotuj model**. Godzinny wykład to zwykle 5–15 minut
transkrypcji – zostaw wtedy Skrybę otwartą (ekran nie gaśnie sam).

## Praca w tle

- **Nagrywanie** trwa przy zablokowanym ekranie i w innych aplikacjach (nawet kilka godzin).
  Nie zamykaj tylko Skryby w przełączniku aplikacji (przesunięcie w górę) – to ją wyłącza.
- **Transkrypcja** też trwa w tle: Skryba odtwarza wtedy ciszę (nie słychać jej, muzyka i filmy
  w innych aplikacjach grają normalnie), nie używa karty graficznej i robi przerwy, żeby iOS
  nie zamknął jej za zużycie procesora – w tle jest więc wolniejsza niż na ekranie.
- **Gdy nagrywasz i wyjdziesz ze Skryby**, transkrypcja innego nagrania czeka (zwalnia pamięć),
  żeby system na pewno nie przerwał nagrywania. Ruszy sama po powrocie do aplikacji.
- **iOS/iPadOS 27** może nie pozwalać na obliczenia AI w tle. Skryba sprawdza to sama: jeśli
  system odmówi, transkrypcja w tle czeka i po powrocie rusza dalej od miejsca, w którym stanęła
  (bez zaczynania od nowa). Stan widać w Ustawienia → Diagnostyka → „Transkrypcja w tle”.

## Udostępnianie z Dyktafonu

1. Dyktafon → wybierz nagranie → **Udostępnij** → **Skryba**.
2. Jeśli Skryba poprosi o folder (tylko za pierwszym razem i tylko wtedy, gdy instalacja nie
   dostała App Group): wejdź do **Na moim iPadzie / iPhonie → Skryba** i dotknij **Otwórz**.
3. Otwórz Skrybę albo dotknij powiadomienia – nagranie doda się samo i ruszy transkrypcja.

Zawsze działa też: Udostępnij → **Zachowaj w Plikach** → Na moim iPadzie → **Skryba** → Zapisz.
Do folderu Skryby możesz też kopiować pliki z komputera (iTunes/Finder → Udostępnianie plików).

## Gdy coś nie działa

- **Ustawienia → Diagnostyka → Dziennik zdarzeń** – zapis pobierania i przygotowania modelu,
  transkrypcji, importów i błędów. Zrób zrzut ekranu i wyślij go autorowi.
- **„Nie udało się uruchomić modelu Whisper”** – wybierz w Ustawieniach model „Szybki”.
- **Sideloadly zgłasza błąd przy instalacji** – użyj pliku `Skryba-zapasowa-bez-AppGroup.ipa`;
  nagrania z Dyktafonu przekażesz wtedy przez folder Skryba (Skryba sama o niego poprosi).
- **Błąd budowania na GitHubie** – otwórz czerwony krzyżyk w zakładce Actions, zrób zrzut
  ekranu z treścią błędu i wyślij go.

## Prywatność

Nagrania i transkrypcje są zapisane tylko na Twoim urządzeniu. Whisper działa w całości
lokalnie. Dźwięk opuszcza urządzenie tylko wtedy, gdy wybierzesz silnik Apple dla języka,
którego Apple nie obsługuje offline.

## Struktura projektu

```
Skryba/                aplikacja (SwiftUI, iOS 17+, iPhone i iPad)
  AppModel.swift       stan aplikacji, nagrywanie, importy, kopiowanie
  Audio/               nagrywanie, odtwarzacz, import plików, dekodowanie i cięcie w ciszy
  Models/              biblioteka nagrań, ustawienia, dziennik diagnostyczny
  Transcription/       Whisper na urządzeniu (WhisperKit), silniki Apple, kolejka z wznawianiem
  Views/               ekrany: biblioteka, nagrywanie, szczegóły, ustawienia
SkrybaShare/           rozszerzenie „Skryba” w arkuszu udostępniania
Shared/                kod wspólny: App Group, folder Skryba, kolory
Config/                Info.plist, uprawnienia, Signing.xcconfig (identyfikator aplikacji)
.github/workflows/     budowanie pliku .ipa na GitHubie
```
