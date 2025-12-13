# Personal Dashboard

A modern, customizable personal dashboard application built with the PERN stack (PostgreSQL, Express, React, Node.js). This application allows you to manage Tasks, Lists, and Notes in a single, beautiful interface.

## Tech Stack

- **Frontend**: React 19, Vite, Tailwind CSS 4, Lucide React
- **Backend**: Node.js, Express
- **Database**: PostgreSQL
- **Language**: JavaScript (ES Modules)

## Project Structure

- `client/`: React frontend application
- `server/`: Express backend application

## Version info

Current Version: **v0.1.0**

 See [CHANGELOG.md](./CHANGELOG.md) for full history.


## Getting Started

### Prerequisites

- Node.js (v18+)
- PostgreSQL

### Installation

1. **Clone the repository**
   ```bash
   git clone <repository-url>
   cd personal-dashboard
   ```

2. **Setup Server**
   ```bash
   cd server
   npm install
   # Create a .env file based on .env.example (to be created)
   # npm start (or whatever script is defined)
   ```

3. **Setup Client**
   ```bash
   cd client
   npm install
   npm run dev
   ```

## Features

- **Task Management**: Organize tasks efficiently.
- **Lists**: Create and manage custom lists.
- **Notes**: Keep track of thoughts and ideas.
- **Dashboard**: A unified view of your personal data.
