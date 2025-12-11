# User Service API

A simple Node.js REST API for user management built with Express.js.

## Features

- CRUD operations for users
- Input validation
- Error handling
- Health check endpoint
- CORS enabled
- Security headers with Helmet

## API Endpoints

### Health Check
- `GET /health` - Check if the service is running

### Users
- `GET /api/users` - Get all users
- `GET /api/users/:id` - Get user by ID
- `POST /api/users` - Create a new user
- `PUT /api/users/:id` - Update user by ID
- `DELETE /api/users/:id` - Delete user by ID

## Request/Response Examples

### Get all users
```bash
curl -X GET http://localhost:3000/api/users
```

### Create a new user
```bash
curl -X POST http://localhost:3000/api/users \
  -H "Content-Type: application/json" \
  -d '{"name": "Alice Johnson", "email": "alice@example.com"}'
```

### Update a user
```bash
curl -X PUT http://localhost:3000/api/users/1 \
  -H "Content-Type: application/json" \
  -d '{"name": "John Updated", "email": "john.updated@example.com"}'
```

### Delete a user
```bash
curl -X DELETE http://localhost:3000/api/users/1
```

## Installation and Setup

1. Install dependencies:
```bash
npm install
```

2. Start the server:
```bash
npm start
```

3. For development with auto-reload:
```bash
npm run dev
```

The server will start on port 3000 by default. You can change this by setting the `PORT` environment variable.

## Environment Variables

- `PORT` - Server port (default: 3000)
- `NODE_ENV` - Environment mode (development/production)

## Deployment

This API is configured for deployment on AWS Lightsail with automatic GitHub Actions integration.
