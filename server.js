const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const { v4: uuidv4 } = require('uuid');
require('dotenv').config();

const app = express();
const PORT = process.env.PORT || 3000;

// Middleware
app.use(helmet());
app.use(cors());
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// In-memory storage for demo purposes
let users = [
  {
    id: '1',
    name: 'John Doe',
    email: 'john.doe@example.com',
    createdAt: new Date().toISOString()
  },
  {
    id: '2',
    name: 'Jane Smith',
    email: 'jane.smith@example.com',
    createdAt: new Date().toISOString()
  }
];

// Routes

// Health check endpoint
app.get('/health', (req, res) => {
  res.status(200).json({
    status: 'OK',
    message: 'User Service is running',
    timestamp: new Date().toISOString()
  });
});

// Get all users
app.get('/api/users', (req, res) => {
  res.status(200).json({
    success: true,
    data: users,
    count: users.length
  });
});

// Get user by ID
app.get('/api/users/:id', (req, res) => {
  const { id } = req.params;
  const user = users.find(u => u.id === id);
  
  if (!user) {
    return res.status(404).json({
      success: false,
      message: 'User not found'
    });
  }
  
  res.status(200).json({
    success: true,
    data: user
  });
});

// Create new user
app.post('/api/users', (req, res) => {
  const { name, email } = req.body;
  
  if (!name || !email) {
    return res.status(400).json({
      success: false,
      message: 'Name and email are required'
    });
  }
  
  // Check if email already exists
  const existingUser = users.find(u => u.email === email);
  if (existingUser) {
    return res.status(409).json({
      success: false,
      message: 'User with this email already exists'
    });
  }
  
  const newUser = {
    id: uuidv4(),
    name,
    email,
    createdAt: new Date().toISOString()
  };
  
  users.push(newUser);
  
  res.status(201).json({
    success: true,
    data: newUser,
    message: 'User created successfully'
  });
});

// Update user
app.put('/api/users/:id', (req, res) => {
  const { id } = req.params;
  const { name, email } = req.body;
  
  const userIndex = users.findIndex(u => u.id === id);
  
  if (userIndex === -1) {
    return res.status(404).json({
      success: false,
      message: 'User not found'
    });
  }
  
  if (name) users[userIndex].name = name;
  if (email) {
    // Check if email already exists for another user
    const existingUser = users.find(u => u.email === email && u.id !== id);
    if (existingUser) {
      return res.status(409).json({
        success: false,
        message: 'Email already exists for another user'
      });
    }
    users[userIndex].email = email;
  }
  
  users[userIndex].updatedAt = new Date().toISOString();
  
  res.status(200).json({
    success: true,
    data: users[userIndex],
    message: 'User updated successfully'
  });
});

// Delete user
app.delete('/api/users/:id', (req, res) => {
  const { id } = req.params;
  const userIndex = users.findIndex(u => u.id === id);
  
  if (userIndex === -1) {
    return res.status(404).json({
      success: false,
      message: 'User not found'
    });
  }
  
  users.splice(userIndex, 1);
  
  res.status(200).json({
    success: true,
    message: 'User deleted successfully'
  });
});

// 404 handler
app.use('*', (req, res) => {
  res.status(404).json({
    success: false,
    message: 'Route not found'
  });
});

// Error handler
app.use((err, req, res, next) => {
  console.error(err.stack);
  res.status(500).json({
    success: false,
    message: 'Internal server error'
  });
});

// Start server
app.listen(PORT, () => {
  console.log(`User Service is running on port ${PORT}`);
  console.log(`Health check: http://localhost:${PORT}/health`);
  console.log(`API endpoints: http://localhost:${PORT}/api/users`);
});

module.exports = app;
