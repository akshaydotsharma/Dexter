# Personal Dashboard

A modern, customizable personal dashboard application built with the PERN stack (PostgreSQL, Express, React, Node.js). This application allows you to manage Tasks, Lists, and Notes in a single, beautiful interface.

## Tech Stack

- **Frontend**: React 19, Vite, Tailwind CSS 4, Lucide React
- **Backend**: Node.js, Express
- **Database**: PostgreSQL
- **Mobile**: Native iOS app in SwiftUI (see `mobile/`)
- **AI**: Anthropic Claude (chat, draft suggestions)
- **Language**: JavaScript (ES Modules), Swift

## Project Structure

- `client/`: React frontend application
- `server/`: Express backend application
- `mobile/`: Native iOS app (SwiftUI)

## Version info

Current Version: **v0.1.0**

 See [CHANGELOG.md](./CHANGELOG.md) for full history.


## Getting Started

### Prerequisites

- Node.js (v18+)
- PostgreSQL (running locally or reachable via `DATABASE_URL`)
- An Anthropic API key for the chat / AI draft features (https://console.anthropic.com/settings/keys)
- Xcode 16+ if you want to build the iOS app

### Installation

1. **Clone the repository**
   ```bash
   git clone <repository-url>
   cd personal-dashboard
   ```

2. **Configure environment variables**

   The repo ships with no secrets. Copy the example files and fill in your own:

   ```bash
   cp server/.env.example server/.env   # then edit server/.env
   cp client/.env.example client/.env   # optional, only if you need overrides
   ```

   At minimum you must set:
   - `ANTHROPIC_API_KEY` in `server/.env` (otherwise chat/AI endpoints return an error)
   - `DATABASE_URL` in `server/.env` pointing at your Postgres instance

   Both `.env` files are gitignored, so your keys never enter version control.

3. **Install dependencies and run**
   ```bash
   # From the repo root, installs root + client + server
   npm run install:all
   npm start                            # runs server (3000) + client (Vite, 5173) together
   ```

   Or run them separately:
   ```bash
   cd server && npm install && npm run dev
   cd client && npm install && npm run dev
   ```

4. **iOS app (optional)**

   The iOS client lives in `mobile/`. By default it talks to `http://localhost:3000/api`,
   which works for the iOS Simulator on the same Mac as the server. For a physical
   device you need a publicly reachable URL: either set the `API_URL` environment
   variable in the Xcode scheme, or temporarily edit `mobile/PersonalDashboard/App/AppConfig.swift`
   before archiving.

   See `mobile/README.md` and `mobile/RELEASE.md` for the OTA install flow.

## Features

- **Task Management**: Organize tasks efficiently.
- **Lists**: Create and manage custom lists.
- **Notes**: Keep track of thoughts and ideas.
- **Dashboard**: A unified view of your personal data.
