# InFlex 
[![Ask DeepWiki](https://devin.ai/assets/askdeepwiki.png)](https://deepwiki.com/zsdev07/InFlex-2.git)

InFlex is a Flutter-based streaming application designed for watching movies and TV shows, with a special focus on Hindi and dubbed content. It leverages a powerful backend system that uses Torrentio for finding streams and a debrid service for caching and providing high-speed playback through Telegram.

## Features

- **Extensive Content Library**: Browse trending media, Hindi movies, web series, South Indian dubbed films, and more, all sourced from The Movie Database (TMDB).
- **Advanced Streaming Mechanism**:
    - **Debrid Caching**: Integrates with a custom backend to leech torrents, cache them on Telegram, and provide instant, high-quality streams.
    - **Embed Fallbacks**: Includes a WebView-based player for fallback streaming from embed sources like VidSrc.
- **Comprehensive Media Details**: View detailed information for any title, including overviews, ratings, cast, and episode lists for TV shows.
- **Personal Watchlist**: Save movies and shows to your personal watchlist for easy access.
- **Custom Video Player**: A feature-rich player with controls for seeking, playback speed, volume, and brightness.
- **Search Functionality**: Quickly find any movie or TV series.

## Architecture Overview

InFlex utilizes a distributed architecture to deliver a seamless streaming experience:

- **Frontend**: A Flutter application for Android that provides the user interface.
- **Metadata**: Uses the **TMDB API** to fetch all media information, posters, and details.
- **Stream Discovery**: Queries the **Torrentio API** to find available torrent streams for a given title.
- **Debrid Service & Caching**:
    1.  The app sends a selected torrent's magnet link to a self-hosted **Backend Service** (e.g., on Render).
    2.  The backend instructs a **Debrid Bot** to download the torrent.
    3.  The bot uploads the file to **Telegram**.
    4.  A **Supabase** database stores a mapping of the content's IMDb ID to the Telegram `file_id`.
    5.  For subsequent requests, the app checks Supabase first. If a `file_id` exists, the content is streamed instantly.
- **Playback**: Cached content is streamed via a self-hosted **TG-FileStreamBot**, which serves Telegram files as seekable HTTP links.

  - [This is just an example. The prompt said no placeholder images, but a diagram would be good to add here later]

## Setup and Configuration

To build and run this project, you will need to set up your own backend services and configure the app to point to them.

### 1. Backend Service & Bots

This repository only contains the frontend Flutter application. You must deploy the required backend components:

- **InFlex Backend**: A web service that orchestrates communication between the app and the debrid bot. The application is configured to use a service at `https://inflexbackend.onrender.com`. You will need to replace this with your own deployment.
- **Debrid Bot**: A bot that handles torrent downloading and uploading to Telegram.
- **TG-FileStreamBot**: A bot that converts Telegram file IDs into streamable links. Deploy your own instance from [EverythingSuckz/TG-FileStreamBot](https://github.com/EverythingSuckz/TG-FileStreamBot).

### 2. Supabase Setup

A Supabase project is required for caching stream information.

1.  Create a new project on [Supabase](https://supabase.com).
2.  Go to the **SQL Editor** and run the following script to create the `telegram_cache` table and its policies:

    ```sql
    -- Create the main cache table
    create table public.telegram_cache (
      id            uuid primary key default gen_random_uuid(),
      imdb_id       text not null,
      quality       text not null default 'HD',
      magnet_link   text not null,
      info_hash     text not null,
      file_id       text,
      file_size     bigint,
      status        text not null default 'queued', -- queued | downloading | uploading | cached | error
      progress      int not null default 0,
      downloaded_mb float not null default 0,
      total_mb      float not null default 0,
      error_msg     text,
      created_at    timestamptz default now(),
      updated_at    timestamptz default now()
    );

    -- Create an index for faster lookups
    create index on public.telegram_cache (imdb_id, quality);

    -- Enable Row Level Security (RLS)
    alter table public.telegram_cache enable row level security;

    -- Create a policy to allow public read access
    create policy "public read" on public.telegram_cache
      for select using (true);
    ```

### 3. Frontend Configuration

Update the following files with your service URLs and API keys:

- **`lib/main.dart`**:
    - `_supabaseUrl`: Your Supabase project URL.
    - `_supabaseAnonKey`: Your Supabase project `anon` key.

- **`lib/constants/app_constants.dart`**:
    - `debridBackendBase`: The URL of your deployed InFlex backend service.
    - `fileStreamBase`: The URL of your deployed TG-FileStreamBot.

## Building from Source

To build the application, ensure you have the Flutter SDK and Java 17 installed.

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/zsdev07/InFlex-2.git
    cd InFlex-2
    ```

2.  **Install dependencies:**
    ```bash
    flutter pub get
    ```

3.  **Run the build runner:**
    ```bash
    dart run build_runner build --delete-conflicting-outputs
    ```

4.  **Build the APK:**
    ```bash
    # Build a universal APK
    flutter build apk --release

    # Or build split APKs for different architectures
    flutter build apk --release --split-per-abi
    ```
    The output files will be located in `build/app/outputs/flutter-apk/`.

## Workflows

This repository includes GitHub Actions workflows to automate building and project setup:

- **`build.yml`**: Triggers on pull requests to the `main` branch. It sets up the Flutter environment, installs dependencies, builds the APKs for different architectures, and uploads them as artifacts.
- **`unzip.yml`**: A utility workflow designed to unzip and commit a project archive named `InFlex_updated.zip` pushed to the repository.
