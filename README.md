# Skryba – nagrywanie i transkrypcja wykładów (iOS)

Nagrywasz wykład → po zatrzymaniu Skryba od razu robi transkrypcję → jednym przyciskiem
kopiujesz cały tekst. Możesz też udostępnić nagranie z Dyktafonu prosto do Skryby.

## Co potrafi

- **Nagrywanie** z animowanym wykresem głośności, pauzą i nazwą nagrania. Działa przy
  zablokowanym ekranie i wznawia się samo po rozmowie telefonicznej.
- **Transkrypcja od razu po zatrzymaniu**, z podglądem tekstu na żywo i paskiem postępu.
- **„Kopiuj całość”** – cały tekst trafia do schowka. W Ustawieniach możesz włączyć
  automatyczne kopiowanie i znaczniki czasu `[mm:ss]`.
- **Udostępnianie z Dyktafonu**: Dyktafon → nagranie → Udostępnij → **Skryba**.
- **Odtwarzacz**: dotknięcie czasu przy akapicie odtwarza nagranie od tego miejsca,
  prędkość 0,75–2×, przeskok o 15 s.
- Edycja tekstu, eksport do `.txt`, udostępnianie audio, wyszukiwarka, ponowna
  transkrypcja w innym języku.
- Przerwana transkrypcja (brak internetu, zamknięta aplikacja) **wznawia się od miejsca
  przerwania**.

## Instalacja na iPhonie (ok. 10 minut, za darmo)

Potrzebujesz: **Maca z Xcode 26 lub nowszym** (darmowy w App Store), **iPhone’a z iOS 17+**
(najlepiej iOS 26/27), kabla USB i swojego **Apple ID**.

1. Rozpakuj ZIP i otwórz `Skryba.xcodeproj`.
2. Xcode → **Settings → Accounts** → „+” → Apple ID → zaloguj się.
3. Kliknij niebieską ikonę projektu **Skryba** (lewy panel) → target **Skryba** →
   karta **Signing & Capabilities** → **Team**: wybierz „Twoje Imię (Personal Team)”.
   **To samo zrób dla targetu `SkrybaShare`.**
4. Podłącz iPhone’a, odblokuj go i dotknij „Zaufaj”. Wybierz iPhone’a na górnym pasku Xcode.
5. Naciśnij ▶︎ (Cmd+R).
6. Na iPhonie: **Ustawienia → Prywatność i ochrona → Tryb dewelopera → Włącz** (telefon się
   zrestartuje). Jeśli iPhone pokaże „Niezaufany deweloper”: **Ustawienia → Ogólne → VPN
   i zarządzanie urządzeniem →** Twój Apple ID **→ Ufaj**.

> Z darmowym kontem aplikacja działa **7 dni** – potem podłącz iPhone’a i jeszcze raz naciśnij ▶︎
> (nagrania i transkrypcje zostają). Płatne konto Apple Developer (99 USD/rok) daje rok
> ważności i TestFlight.

## Transkrypcja – Whisper na iPhonie

Domyślnie Skryba używa **Whispera uruchomionego bezpośrednio na iPhonie** (biblioteka
[WhisperKit](https://github.com/argmaxinc/argmax-oss-swift)). Żadnych kont, kluczy ani opłat,
a nagrania nie opuszczają telefonu.

- **Model pobiera się raz** przy pierwszej transkrypcji albo przyciskiem w Ustawieniach
  („Pobierz model teraz”). Najlepiej przez Wi-Fi, przy otwartej aplikacji.
  - **Dokładny** (Large v3, ok. 630 MB) – najlepszy dla polskiego, domyślny na iPhone’ach z 6 GB+ RAM.
  - **Szybki** (Small, ok. 250 MB) – ok. 3× szybszy, ale mniej dokładny; domyślny na starszych.
- **Pierwsze uruchomienie modelu** trwa dłużej (iOS przygotowuje go pod Twój procesor) – potem
  startuje w kilka sekund.
- **Czas:** godzinny wykład to zwykle 5–15 minut na iPhonie 13 lub nowszym. Ekran nie gaśnie,
  dopóki transkrypcja trwa. Jeśli wyjdziesz z aplikacji, wznowi się od ostatniego fragmentu.
- Alternatywa w Ustawieniach: **rozpoznawanie mowy Apple** (szybsze, ale dla polskiego idzie
  przez serwery Apple i słabiej radzi sobie z dźwiękiem z sali).

> Przy pierwszym otwarciu projektu Xcode pobierze bibliotekę WhisperKit (potrzebny internet,
> chwilę to trwa – widać to na pasku stanu Xcode).

## Udostępnianie z Dyktafonu

1. Dyktafon → wybierz nagranie → **•••** (albo ikona udostępniania) → **Udostępnij**.
2. Wybierz:
   - **Skryba** – aplikacja otworzy się i od razu zrobi transkrypcję,
   - **Transkrybuj** – nagranie zapisze się w tle; otwórz Skrybę albo dotknij powiadomienia.
3. Nie widzisz ikony? Przewiń rząd aplikacji do końca → **Więcej** → włącz Skrybę.

Działa też z aplikacją Pliki, WhatsAppem itp. (każdy plik audio lub wideo) oraz przez
przycisk importu w samej Skrybie.

## Rozwiązywanie problemów

- **„Failed to register bundle identifier” / „App ID is not available”** – otwórz
  `Config/Signing.xcconfig` i zmień `APP_BUNDLE_ID` na coś unikalnego, np.
  `pl.jankowalski.skryba`. Oba targety same pobiorą nową wartość.
- **Błąd podpisywania wspominający „App Groups”** – w obu targetach: Signing & Capabilities →
  sekcja App Groups → ikona kosza. Aplikacja zadziała; z Dyktafonu używaj opcji **Skryba**.
- **„Nie udało się uruchomić modelu Whisper”** – na starszym iPhonie wybierz w Ustawieniach
  model „Szybki”.
- **Xcode: „Missing package product WhisperKit”** – File → Packages → Reset Package Caches
  (potrzebny internet).
- **„Rozpoznawanie mowy Apple zgłosiło błąd”** (tylko silnik Apple) – sprawdź internet i włącz
  dyktowanie: Ustawienia → Ogólne → Klawiatura → Włącz dyktowanie.
- **Xcode starszy niż 26** – projekt się zbuduje, ale bez nowego silnika Apple i bez efektu
  Liquid Glass.
- **Jakikolwiek błąd kompilacji** – skopiuj jego treść z Xcode (panel Issues) i wyślij mi.

## Nie masz Maca?

- Najprościej: pożycz Maca na 15 minut (znajomy, pracownia na uczelni).
- Albo zbuduj w chmurze: wrzuć ten folder do repozytorium na GitHubie → zakładka **Actions** →
  **Zbuduj IPA** → **Run workflow** → pobierz artefakt `Skryba.ipa` i zainstaluj go programem
  **Sideloadly** (Windows/macOS) ze swoim Apple ID. Przy tej metodzie rozszerzenie
  „Transkrybuj” może nie działać – używaj opcji **Skryba**.

## Prywatność

Nagrania i transkrypcje są zapisane tylko na Twoim iPhonie. Whisper działa w całości na telefonie.
Dźwięk opuszcza iPhone’a tylko wtedy, gdy wybierzesz silnik Apple dla języka, którego Apple nie
obsługuje offline (wtedy trafia do serwerów Apple).

## Struktura projektu

```
Skryba/                aplikacja (SwiftUI, iOS 17+)
  AppModel.swift       stan aplikacji, nagrywanie, import, kopiowanie
  Audio/               nagrywanie, odtwarzacz, import plików, dekodowanie i cięcie w ciszy
  Transcription/       silniki: Whisper na iPhonie (WhisperKit), Apple SpeechAnalyzer (iOS 26+),
                       Apple SFSpeechRecognizer + kolejka z punktami kontrolnymi
  Views/               ekrany: biblioteka, nagrywanie, szczegóły, ustawienia
SkrybaShare/           rozszerzenie „Transkrybuj” (arkusz udostępniania)
Shared/                kod wspólny dla aplikacji i rozszerzenia
Config/                Info.plist, uprawnienia, Signing.xcconfig (identyfikator aplikacji)
```
