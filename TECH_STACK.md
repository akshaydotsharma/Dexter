# Tech Stack Reference Guide

## The "Golden Trio" (Frontend)
Every modern frontend app needs three key players: a **Builder**, a **Structure**, and a **Stylist**.

| Role | Technology | Analogy | Real-World Job |
| :--- | :--- | :--- | :--- |
| **The Builder** | **Vite** | **The Factory** 🏭 | Bundles your code. Translates imports/JSX into something the browser understands. |
| **The Structure** | **React** | **The Robot Parts** 🤖 | Defines logic & components. "If I click this, update that." |
| **The Stylist** | **Tailwind** | **The Paint** 🎨 | Handles appearance. "Make this button blue and round." |

---

## The Engine (Backend & Tooling)

### Node.js
*   **Analogy:** **The Kitchen** 👨‍🍳
*   **Role 1 (Dev):** The workspace where Vite runs to "cook" (build) your React app.
*   **Role 2 (Prod):** The server that stays running to listen for API requests and talk to the database.
*   **Key Concept:** Node.js is the **factory**, Chrome is the **road**. Once the app is built and loaded in Chrome, Node.js is no longer involved in the UI.

---

## Backend Options (The Brain)
You can swap the backend language without changing the frontend.

| Language | Best For... | Use Case |
| :--- | :--- | :--- |
| **Node.js** | **Speed** | Real-time apps, Chat, Dashboards. (What we use). |
| **Python** | **AI / Data** | Machine Learning, Scientific Computing. |
| **Go** | **Scale** | Massive infrastructure (Uber/Google). |
| **Java** | **Enterprise** | Large corporate teams (Banks). |

---

## Native iOS App (Mobile)

The companion iOS app talks to the same Express backend over REST + SSE.

| Role | Technology | Notes |
| :--- | :--- | :--- |
| **Framework** | **SwiftUI** | Declarative UI, `@Observable` view-models. |
| **Networking** | **URLSession** | `bytes(for:)` for streaming chat (SSE). |
| **Project gen** | **xcodegen** | `.xcodeproj` is regenerated from `mobile/project.yml`. |
| **Distribution** | **Free dev signing** | OTA install via Cloudflare quick tunnel (`mobile/ota/ship.sh`). 7-day profile rotation. |

---

## AI Layer

| Role | Technology | Notes |
| :--- | :--- | :--- |
| **Provider** | **Anthropic Claude** | Via `@ai-sdk/anthropic` (Vercel AI SDK). Requires `ANTHROPIC_API_KEY`. |
| **Pipeline** | **Tool calls -> drafts** | `server/ai/chatToDrafts.js` turns user text into a structured `Draft` row before any DB writes. |
| **Streaming** | **Server-Sent Events** | `/api/ai/parse/stream`. Both web and iOS clients consume the same wire format (`event: drafts/text/done/error`). |
