#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
AUTO_MODE=${AUTO_MODE:-false}
AWS_REGION=${AWS_REGION:-us-east-1}
APP_VERSION=${APP_VERSION:-1.0.0}

# Fully automated mode environment variables
APP_TYPE=${APP_TYPE:-}
APP_NAME=${APP_NAME:-}
INSTANCE_NAME=${INSTANCE_NAME:-}
BLUEPRINT_ID=${BLUEPRINT_ID:-ubuntu_22_04}
BUNDLE_ID=${BUNDLE_ID:-micro_3_0}
DATABASE_TYPE=${DATABASE_TYPE:-none}
DB_EXTERNAL=${DB_EXTERNAL:-false}
DB_RDS_NAME=${DB_RDS_NAME:-}
DB_NAME=${DB_NAME:-app_db}
ENABLE_BUCKET=${ENABLE_BUCKET:-false}
BUCKET_NAME=${BUCKET_NAME:-}
BUCKET_ACCESS=${BUCKET_ACCESS:-read_write}
BUCKET_BUNDLE=${BUCKET_BUNDLE:-small_1_0}
GITHUB_REPO=${GITHUB_REPO:-}
REPO_VISIBILITY=${REPO_VISIBILITY:-private}

# Function to convert string to lowercase (compatible with older bash versions)
to_lowercase() {
    echo "$1" | tr '[:upper:]' '[:lower:]'
}

# Function to convert string to uppercase (compatible with older bash versions)
to_uppercase() {
    echo "$1" | tr '[:lower:]' '[:upper:]'
}

# Function to check prerequisites
check_prerequisites() {
    echo -e "${BLUE}Checking prerequisites...${NC}"
    
    local missing_tools=()
    
    # Check for required tools
    if ! command -v git &> /dev/null; then
        missing_tools+=("git")
    fi
    
    if ! command -v gh &> /dev/null; then
        missing_tools+=("gh (GitHub CLI)")
    fi
    
    if ! command -v aws &> /dev/null; then
        missing_tools+=("aws (AWS CLI)")
    fi
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        echo -e "${RED}❌ Missing required tools:${NC}"
        for tool in "${missing_tools[@]}"; do
            echo "  - $tool"
        done
        echo ""
        echo "Please install the missing tools and try again."
        exit 1
    fi
    
    # Check GitHub CLI authentication
    if ! gh auth status &> /dev/null; then
        echo -e "${RED}❌ GitHub CLI not authenticated${NC}"
        echo "Please run: gh auth login"
        exit 1
    fi
    
    # Check AWS CLI configuration
    if ! aws sts get-caller-identity &> /dev/null; then
        echo -e "${RED}❌ AWS CLI not configured${NC}"
        echo "Please run: aws configure"
        exit 1
    fi
    
    echo -e "${GREEN}✓ All prerequisites met${NC}"
}

# Function to check if we're in a git repository
check_git_repo() {
    git rev-parse --git-dir &> /dev/null
}

# Function to create GitHub repository if needed
create_github_repo_if_needed() {
    local repo_name="$1"
    local repo_desc="$2"
    local visibility="$3"
    
    echo -e "${BLUE}Creating GitHub repository: $repo_name${NC}"
    
    if gh repo create "$repo_name" --description "$repo_desc" $visibility --confirm; then
        echo -e "${GREEN}✓ Repository created successfully${NC}"
        return 0
    else
        echo -e "${YELLOW}⚠️  Repository might already exist${NC}"
        return 0
    fi
}

# Function to create IAM role for GitHub OIDC
create_iam_role_if_needed() {
    local role_name="$1"
    local github_repo="$2"
    local aws_account_id="$3"
    
    echo -e "${BLUE}Creating IAM role: $role_name${NC}"
    
    # Create trust policy
    cat > trust-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::${aws_account_id}:oidc-provider/token.actions.githubusercontent.com"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
                },
                "StringLike": {
                    "token.actions.githubusercontent.com:sub": "repo:${github_repo}:*"
                }
            }
        }
    ]
}
EOF

    # Create role
    if aws iam create-role --role-name "$role_name" --assume-role-policy-document file://trust-policy.json &> /dev/null; then
        echo -e "${GREEN}✓ IAM role created${NC}"
    else
        echo -e "${YELLOW}⚠️  IAM role might already exist${NC}"
    fi
    
    # Attach policies
    aws iam attach-role-policy --role-name "$role_name" --policy-arn "arn:aws:iam::aws:policy/AmazonLightsailFullAccess" &> /dev/null
    aws iam attach-role-policy --role-name "$role_name" --policy-arn "arn:aws:iam::aws:policy/AmazonS3FullAccess" &> /dev/null
    
    # Set AWS_ROLE_ARN
    AWS_ROLE_ARN="arn:aws:iam::${aws_account_id}:role/${role_name}"
    
    # Clean up
    rm -f trust-policy.json
    
    return 0
}

# Function to setup workflow files (copy from existing repository)
setup_workflow_files() {
    echo -e "${BLUE}Setting up workflow files...${NC}"
    
    mkdir -p .github/workflows
    
    # Check if we already have the reusable workflow
    if [[ ! -f ".github/workflows/deploy-generic-reusable.yml" ]]; then
        echo -e "${BLUE}Copying reusable workflow from source repository...${NC}"
        
        # Download the reusable workflow
        curl -s -o ".github/workflows/deploy-generic-reusable.yml" \
            "https://raw.githubusercontent.com/naveenraj44125-creator/lamp-stack-lightsail/main/.github/workflows/deploy-generic-reusable.yml"
        
        if [[ -f ".github/workflows/deploy-generic-reusable.yml" ]]; then
            echo -e "${GREEN}✓ Reusable workflow downloaded${NC}"
        else
            echo -e "${RED}❌ Failed to download reusable workflow${NC}"
            return 1
        fi
    else
        echo -e "${GREEN}✓ Reusable workflow already exists${NC}"
    fi
    
    return 0
}

# Function to create deployment configuration based on existing examples
create_deployment_config() {
    local app_type="$1"
    local app_name="$2"
    local instance_name="$3"
    local aws_region="$4"
    local blueprint_id="$5"
    local bundle_id="$6"
    local db_type="$7"
    local db_external="$8"
    local db_rds_name="$9"
    local db_name="${10}"
    local bucket_name="${11}"
    local bucket_access="${12}"
    local bucket_bundle="${13}"
    local enable_bucket="${14}"
    
    echo -e "${BLUE}Creating deployment configuration for $app_type...${NC}"
    
    # Base configuration that matches our existing examples
    cat > "deployment-${app_type}.config.yml" << EOF
# ${app_name} Deployment Configuration

aws:
  region: ${aws_region}

lightsail:
  instance_name: ${instance_name}
  static_ip: ""
  
  # Instance size configuration (optional)
  # If not specified, defaults are: small_3_0 (2GB) for traditional apps, medium_3_0 (4GB) for Docker apps
  bundle_id: "${bundle_id}"
  
  # Operating system blueprint configuration (optional)
  # If not specified, defaults to ubuntu_22_04
  blueprint_id: "${blueprint_id}"

EOF

    # Add bucket configuration if enabled
    if [[ "$enable_bucket" == "true" ]]; then
        cat >> "deployment-${app_type}.config.yml" << EOF
  # Lightsail bucket configuration
  bucket:
    enabled: true
    name: "${bucket_name}"
    access_level: "${bucket_access}"
    bundle_id: "${bucket_bundle}"

EOF
    fi

    # Application configuration based on type
    cat >> "deployment-${app_type}.config.yml" << EOF
application:
  name: $(echo "${app_name}" | tr '[:upper:]' '[:lower:]')
  version: "1.0.0"
  type: ${app_type}
  
  package_files:
    - "example-${app_type}-app/"
  
  package_fallback: true
  
  environment_variables:
    APP_ENV: production
EOF

    # Add database environment variables (available for all application types)
    if [[ "$db_type" != "none" ]]; then
        cat >> "deployment-${app_type}.config.yml" << EOF
    # Database Configuration
    DB_TYPE: ${db_type}
    DB_HOST: $([ "$db_external" = "true" ] && echo "RDS_ENDPOINT" || echo "localhost")
    DB_NAME: ${db_name:-app_db}
    DB_USER: app_user
    DB_PASSWORD: CHANGE_ME_secure_password_123
EOF
        if [[ "$db_external" == "true" ]]; then
            cat >> "deployment-${app_type}.config.yml" << EOF
    DB_RDS_NAME: ${db_rds_name:-${app_type}-${db_type}-db}
EOF
        fi
    fi

    # Add type-specific environment variables
    case $app_type in
        "lamp")
            cat >> "deployment-${app_type}.config.yml" << EOF
    # LAMP Stack specific
    APACHE_DOCUMENT_ROOT: /var/www/html
EOF
            ;;
        "nodejs")
            cat >> "deployment-${app_type}.config.yml" << EOF
    # Node.js specific
    NODE_ENV: production
    PORT: "3000"
EOF
            ;;
        "python")
            cat >> "deployment-${app_type}.config.yml" << EOF
    # Python/Flask specific
    FLASK_ENV: production
    FLASK_APP: app.py
    PORT: "5000"
EOF
            ;;
        "react")
            cat >> "deployment-${app_type}.config.yml" << EOF
    # React specific
    REACT_APP_ENV: production
    BUILD_PATH: build
EOF
            ;;
        "docker")
            cat >> "deployment-${app_type}.config.yml" << EOF
    # Docker specific
    COMPOSE_PROJECT_NAME: $(to_lowercase "${app_name}")
    DOCKER_BUILDKIT: "1"
EOF
            ;;
        "nginx")
            cat >> "deployment-${app_type}.config.yml" << EOF
    # Nginx specific
    NGINX_DOCUMENT_ROOT: /var/www/html
EOF
            ;;
    esac

    # Add bucket environment variables if enabled
    if [[ "$enable_bucket" == "true" ]]; then
        cat >> "deployment-${app_type}.config.yml" << EOF
    BUCKET_NAME: ${bucket_name}
    AWS_REGION: ${aws_region}
EOF
    fi

    # Dependencies configuration based on app type
    cat >> "deployment-${app_type}.config.yml" << EOF

dependencies:
EOF

    # Database configuration (available for all application types)
    cat >> "deployment-${app_type}.config.yml" << EOF
  # Database Dependencies
  mysql:
    enabled: $([ "$db_type" = "mysql" ] && [ "$db_external" = "false" ] && echo "true" || echo "false")
    external: $([ "$db_external" = "true" ] && echo "true" || echo "false")
    config:
      version: "8.0"
      root_password: "CHANGE_ME_root_password_123"
      create_database: "${db_name:-app_db}"
      create_user: "app_user"
      user_password: "CHANGE_ME_secure_password_123"
EOF

    if [[ "$db_external" == "true" && "$db_type" == "mysql" ]]; then
        cat >> "deployment-${app_type}.config.yml" << EOF
    rds:
      database_name: "${db_rds_name:-${app_type}-mysql-db}"
      region: "${aws_region}"
      master_database: "${db_name:-app_db}"
      environment:
        DB_CONNECTION_TIMEOUT: "30"
        DB_CHARSET: "utf8mb4"
EOF
    fi

    cat >> "deployment-${app_type}.config.yml" << EOF
  
  postgresql:
    enabled: $([ "$db_type" = "postgresql" ] && [ "$db_external" = "false" ] && echo "true" || echo "false")
    external: $([ "$db_external" = "true" ] && echo "true" || echo "false")
    config:
      version: "13"
      postgres_password: "CHANGE_ME_postgres_password_123"
      create_database: "${db_name:-app_db}"
      create_user: "app_user"
      user_password: "CHANGE_ME_secure_password_123"
EOF

    if [[ "$db_external" == "true" && "$db_type" == "postgresql" ]]; then
        cat >> "deployment-${app_type}.config.yml" << EOF
    rds:
      database_name: "${db_rds_name:-${app_type}-postgres-db}"
      region: "${aws_region}"
      master_database: "${db_name:-app_db}"
      environment:
        DB_CONNECTION_TIMEOUT: "30"
EOF
    fi

    case $app_type in
        "lamp")
            cat >> "deployment-${app_type}.config.yml" << EOF
  
  php:
    enabled: true
    config:
      version: "8.1"
      extensions:
        - curl
        - json
        - mbstring
        - mysql
        - xml
        - zip
      
  apache:
    enabled: true
    config:
      enable_rewrite: true
      document_root: "/var/www/html"
EOF
            ;;
        "nodejs")
            cat >> "deployment-${app_type}.config.yml" << EOF
  
  nodejs:
    enabled: true
    config:
      version: "18"
      package_manager: "npm"
      
  pm2:
    enabled: true
    config:
      app_name: "$(to_lowercase "${app_name}")"
      instances: 1
      exec_mode: "cluster"
EOF
            ;;
        "python")
            cat >> "deployment-${app_type}.config.yml" << EOF
  
  python:
    enabled: true
    config:
      version: "3.9"
      pip_packages:
        - flask
        - gunicorn
        
  gunicorn:
    enabled: true
    config:
      app_module: "app:app"
      workers: 2
      bind: "0.0.0.0:5000"
EOF
            ;;
        "nginx")
            cat >> "deployment-${app_type}.config.yml" << EOF
  nginx:
    enabled: true
    config:
      document_root: "/var/www/html"
      enable_gzip: true
      client_max_body_size: "10M"
EOF
            ;;
        "docker")
            cat >> "deployment-${app_type}.config.yml" << EOF
  docker:
    enabled: true
    config:
      install_compose: true
EOF
            ;;
    esac

    # Common dependencies
    cat >> "deployment-${app_type}.config.yml" << EOF
  
  git:
    enabled: true
    config:
      install_lfs: false
  
  firewall:
    enabled: true
    config:
      allowed_ports:
        - "22"    # SSH
        - "80"    # HTTP
        - "443"   # HTTPS
EOF

    # Add type-specific ports
    case $app_type in
        "nodejs")
            cat >> "deployment-${app_type}.config.yml" << EOF
        - "3000"  # Node.js
EOF
            ;;
        "python")
            cat >> "deployment-${app_type}.config.yml" << EOF
        - "5000"  # Flask
EOF
            ;;
        "lamp")
            cat >> "deployment-${app_type}.config.yml" << EOF
        - "8080"  # phpMyAdmin
EOF
            ;;
    esac

    cat >> "deployment-${app_type}.config.yml" << EOF
      deny_all_other: true

deployment:
EOF

    # Add Docker-specific deployment config
    if [[ "$app_type" == "docker" ]]; then
        cat >> "deployment-${app_type}.config.yml" << EOF
  use_docker: true
  docker_app_path: "/opt/$(to_lowercase "${app_name}")-app"
  docker_compose_file: "docker-compose.yml"
EOF
    fi

    # Common deployment configuration
    cat >> "deployment-${app_type}.config.yml" << EOF
  
  timeouts:
    ssh_connection: 120
    command_execution: 600
    health_check: 180
  
  retries:
    max_attempts: 3
    ssh_connection: 5
  
  steps:
    pre_deployment:
      common:
        enabled: true
        update_packages: true
        create_directories: true
        backup_enabled: true
      dependencies:
        enabled: true
        install_system_deps: true
        configure_services: true
    
    post_deployment:
      common:
        enabled: true
        verify_extraction: true
        create_env_file: true
        cleanup_temp_files: true
      dependencies:
        enabled: true
        configure_application: true
        set_permissions: true
        restart_services: true
    
    verification:
      enabled: true
      health_check: true
      external_connectivity: true
      endpoints_to_test:
        - "/"
EOF

    # Add type-specific endpoints
    case $app_type in
        "nodejs")
            cat >> "deployment-${app_type}.config.yml" << EOF
        - "/api/health"
EOF
            ;;
        "python")
            cat >> "deployment-${app_type}.config.yml" << EOF
        - "/api/health"
EOF
            ;;
        "lamp")
            cat >> "deployment-${app_type}.config.yml" << EOF
        - "/api/test.php"
EOF
            ;;
    esac

    # GitHub Actions configuration
    cat >> "deployment-${app_type}.config.yml" << EOF

github_actions:
  triggers:
    push_branches:
      - main
      - master
    pull_request_branches:
      - main
      - master
    workflow_dispatch: true
  
  jobs:
    test:
      enabled: true
EOF

    # Add type-specific test configuration
    case $app_type in
        "docker")
            cat >> "deployment-${app_type}.config.yml" << EOF
      docker_test: true
EOF
            ;;
        *)
            cat >> "deployment-${app_type}.config.yml" << EOF
      language_specific_tests: true
EOF
            ;;
    esac

    cat >> "deployment-${app_type}.config.yml" << EOF
    
    deployment:
      deploy_on_push: true
      deploy_on_pr: false
      artifact_retention_days: 1
      create_summary: true

monitoring:
  health_check:
    endpoint: "/"
EOF

    # Add type-specific expected content
    case $app_type in
        "lamp")
            cat >> "deployment-${app_type}.config.yml" << EOF
    expected_content: "LAMP Stack"
EOF
            ;;
        "nodejs")
            cat >> "deployment-${app_type}.config.yml" << EOF
    expected_content: "Node.js"
EOF
            ;;
        "python")
            cat >> "deployment-${app_type}.config.yml" << EOF
    expected_content: "Flask"
EOF
            ;;
        "react")
            cat >> "deployment-${app_type}.config.yml" << EOF
    expected_content: "React"
EOF
            ;;
        "docker")
            cat >> "deployment-${app_type}.config.yml" << EOF
    expected_content: "Docker"
EOF
            ;;
        *)
            cat >> "deployment-${app_type}.config.yml" << EOF
    expected_content: "${app_name}"
EOF
            ;;
    esac

    cat >> "deployment-${app_type}.config.yml" << EOF
    max_attempts: 15
    wait_between_attempts: 20
    initial_wait: 60

security:
  file_permissions:
    web_files: "644"
    directories: "755"
    config_files: "600"

backup:
  enabled: true
  retention_days: 7
  backup_location: "/var/backups/$(to_lowercase "${app_name}")-deployments"
EOF

    # Add Docker-specific monitoring
    if [[ "$app_type" == "docker" ]]; then
        cat >> "deployment-${app_type}.config.yml" << EOF
  
  docker_health:
    check_containers: true
    required_containers:
      - "$(to_lowercase "${app_name}")-web"
EOF
    fi

    echo -e "${GREEN}✓ Created deployment-${app_type}.config.yml${NC}"
}

# Function to create GitHub Actions workflow that matches existing examples
create_github_workflow() {
    local app_type="$1"
    local app_name="$2"
    local aws_region="$3"
    
    echo -e "${BLUE}Creating GitHub Actions workflow...${NC}"
    
    mkdir -p .github/workflows
    
    # Create workflow that matches our existing examples
    cat > ".github/workflows/deploy-${app_type}.yml" << EOF
name: ${app_name} Deployment

on:
  push:
    branches: [ main, master ]
    paths:
      - 'example-${app_type}-app/**'
      - 'deployment-${app_type}.config.yml'
      - '.github/workflows/deploy-${app_type}.yml'
  pull_request:
    branches: [ main, master ]
    paths:
      - 'example-${app_type}-app/**'
      - 'deployment-${app_type}.config.yml'
  workflow_dispatch:
    inputs:
      environment:
        description: 'Deployment environment'
        required: false
        default: 'production'
        type: choice
        options:
          - production
          - staging

permissions:
  id-token: write   # Required for OIDC authentication
  contents: read    # Required to checkout code

jobs:
  deploy:
    name: Deploy ${app_name}
    uses: ./.github/workflows/deploy-generic-reusable.yml
    with:
      config_file: 'deployment-${app_type}.config.yml'
    secrets: inherit
  
  summary:
    name: Deployment Summary
    needs: deploy
    runs-on: ubuntu-latest
    if: always()
    steps:
      - name: Show Deployment Results
        run: |
          echo "## 🚀 ${app_name} Deployment" >> \$GITHUB_STEP_SUMMARY
          echo "" >> \$GITHUB_STEP_SUMMARY
          echo "- **URL**: \${{ needs.deploy.outputs.deployment_url }}" >> \$GITHUB_STEP_SUMMARY
          echo "- **Status**: \${{ needs.deploy.outputs.deployment_status }}" >> \$GITHUB_STEP_SUMMARY
          echo "" >> \$GITHUB_STEP_SUMMARY
          
          if [ "\${{ needs.deploy.outputs.deployment_status }}" = "success" ]; then
            echo "✅ Application deployed successfully!" >> \$GITHUB_STEP_SUMMARY
            echo "" >> \$GITHUB_STEP_SUMMARY
EOF

    # Add type-specific summary information
    case $app_type in
        "lamp")
            cat >> ".github/workflows/deploy-${app_type}.yml" << EOF
            echo "### 🔧 LAMP Stack" >> \$GITHUB_STEP_SUMMARY
            echo "- **Linux**: Ubuntu 22.04" >> \$GITHUB_STEP_SUMMARY
            echo "- **Apache**: Web Server" >> \$GITHUB_STEP_SUMMARY
            echo "- **MySQL**: Database" >> \$GITHUB_STEP_SUMMARY
            echo "- **PHP**: Application Runtime" >> \$GITHUB_STEP_SUMMARY
EOF
            ;;
        "nodejs")
            cat >> ".github/workflows/deploy-${app_type}.yml" << EOF
            echo "### 📡 Endpoints" >> \$GITHUB_STEP_SUMMARY
            echo "- **Home**: \${{ needs.deploy.outputs.deployment_url }}" >> \$GITHUB_STEP_SUMMARY
            echo "- **Health**: \${{ needs.deploy.outputs.deployment_url }}api/health" >> \$GITHUB_STEP_SUMMARY
            echo "- **Info**: \${{ needs.deploy.outputs.deployment_url }}api/info" >> \$GITHUB_STEP_SUMMARY
EOF
            ;;
        "python")
            cat >> ".github/workflows/deploy-${app_type}.yml" << EOF
            echo "### 🐍 Flask API" >> \$GITHUB_STEP_SUMMARY
            echo "- **Home**: \${{ needs.deploy.outputs.deployment_url }}" >> \$GITHUB_STEP_SUMMARY
            echo "- **Health**: \${{ needs.deploy.outputs.deployment_url }}api/health" >> \$GITHUB_STEP_SUMMARY
            echo "- **API**: \${{ needs.deploy.outputs.deployment_url }}api/" >> \$GITHUB_STEP_SUMMARY
EOF
            ;;
        "react")
            cat >> ".github/workflows/deploy-${app_type}.yml" << EOF
            echo "### ⚛️ React Dashboard" >> \$GITHUB_STEP_SUMMARY
            echo "- **Dashboard**: \${{ needs.deploy.outputs.deployment_url }}" >> \$GITHUB_STEP_SUMMARY
            echo "- **Build**: Production optimized" >> \$GITHUB_STEP_SUMMARY
EOF
            ;;
        "docker")
            cat >> ".github/workflows/deploy-${app_type}.yml" << EOF
            echo "### 🐳 Docker Application" >> \$GITHUB_STEP_SUMMARY
            echo "- **Containers**: Multi-container setup" >> \$GITHUB_STEP_SUMMARY
            echo "- **Compose**: Docker Compose orchestration" >> \$GITHUB_STEP_SUMMARY
EOF
            ;;
        "nginx")
            cat >> ".github/workflows/deploy-${app_type}.yml" << EOF
            echo "### 🌐 Static Site" >> \$GITHUB_STEP_SUMMARY
            echo "- **Server**: Nginx" >> \$GITHUB_STEP_SUMMARY
            echo "- **Content**: Static files" >> \$GITHUB_STEP_SUMMARY
EOF
            ;;
    esac

    cat >> ".github/workflows/deploy-${app_type}.yml" << EOF
          else
            echo "❌ Deployment failed. Check logs above." >> \$GITHUB_STEP_SUMMARY
          fi
EOF

    echo -e "${GREEN}✓ Created .github/workflows/deploy-${app_type}.yml${NC}"
}

# Function to create example application that matches existing examples
create_example_app() {
    local app_type="$1"
    local app_name="$2"
    
    echo -e "${BLUE}Creating example ${app_type} application...${NC}"
    
    mkdir -p "example-${app_type}-app"
    
    case $app_type in
        "lamp")
            # Create PHP application similar to existing examples
            cat > "example-${app_type}-app/index.php" << 'PHP_EOF'
<?php
header('Content-Type: text/html; charset=UTF-8');
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>LAMP Stack Application</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; background: #f5f5f5; }
        .container { max-width: 800px; margin: 0 auto; background: white; padding: 30px; border-radius: 10px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        .header { text-align: center; color: #333; margin-bottom: 30px; }
        .info { background: #e8f4fd; padding: 15px; border-radius: 5px; margin: 15px 0; }
        .success { background: #d4edda; color: #155724; padding: 15px; border-radius: 5px; margin: 15px 0; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🚀 LAMP Stack Application</h1>
            <p>Successfully deployed via GitHub Actions</p>
        </div>
        
        <div class="success">
            ✅ Application is running successfully!
        </div>
        
        <div class="info">
            <h3>System Information</h3>
            <p><strong>PHP Version:</strong> <?php echo phpversion(); ?></p>
            <p><strong>Server:</strong> <?php echo $_SERVER['SERVER_SOFTWARE'] ?? 'Unknown'; ?></p>
            <p><strong>Timestamp:</strong> <?php echo date('Y-m-d H:i:s T'); ?></p>
        </div>
        
        <div class="info">
            <h3>Database Connection</h3>
            <?php
            try {
                $host = $_ENV['DB_HOST'] ?? 'localhost';
                $dbname = $_ENV['DB_NAME'] ?? 'app_db';
                $username = $_ENV['DB_USER'] ?? 'app_user';
                $password = $_ENV['DB_PASSWORD'] ?? '';
                
                if ($password) {
                    $pdo = new PDO("mysql:host=$host;dbname=$dbname", $username, $password);
                    echo "<p>✅ Database connection successful</p>";
                } else {
                    echo "<p>⚠️ Database credentials not configured</p>";
                }
            } catch (PDOException $e) {
                echo "<p>⚠️ Database connection failed: " . $e->getMessage() . "</p>";
            }
            ?>
        </div>
    </div>
</body>
</html>
PHP_EOF

            # Create API test endpoint
            mkdir -p "example-${app_type}-app/api"
            cat > "example-${app_type}-app/api/test.php" << 'PHP_EOF'
<?php
header('Content-Type: application/json');
header('Access-Control-Allow-Origin: *');

echo json_encode([
    'status' => 'success',
    'message' => 'LAMP Stack API is working',
    'php_version' => phpversion(),
    'timestamp' => date('c'),
    'server' => $_SERVER['SERVER_SOFTWARE'] ?? 'Unknown'
]);
?>
PHP_EOF
            ;;
        
        "nodejs")
            # Create Node.js application similar to existing examples
            local app_name_lower=$(to_lowercase "${app_name}")
            cat > "example-${app_type}-app/package.json" << EOF
{
  "name": "${app_name_lower}",
  "version": "1.0.0",
  "description": "${app_name} Node.js application deployed via GitHub Actions",
  "main": "app.js",
  "scripts": {
    "start": "node app.js",
    "dev": "nodemon app.js",
    "test": "echo \\"No tests specified\\" && exit 0"
  },
  "dependencies": {
    "express": "^4.18.2",
    "cors": "^2.8.5"
  },
  "devDependencies": {
    "nodemon": "^3.0.1"
  },
  "engines": {
    "node": ">=18.0.0"
  }
}
EOF
            
            cat > "example-${app_type}-app/app.js" << EOF
const express = require('express');
const cors = require('cors');
const app = express();
const PORT = process.env.PORT || 3000;

// Middleware
app.use(cors());
app.use(express.json());
app.use(express.static('public'));

// Routes
app.get('/', (req, res) => {
    res.send(\`
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>${app_name}</title>
            <style>
                body { font-family: Arial, sans-serif; margin: 40px; background: #f5f5f5; }
                .container { max-width: 800px; margin: 0 auto; background: white; padding: 30px; border-radius: 10px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
                .header { text-align: center; color: #333; margin-bottom: 30px; }
                .info { background: #e8f4fd; padding: 15px; border-radius: 5px; margin: 15px 0; }
                .success { background: #d4edda; color: #155724; padding: 15px; border-radius: 5px; margin: 15px 0; }
            </style>
        </head>
        <body>
            <div class="container">
                <div class="header">
                    <h1>🚀 ${app_name}</h1>
                    <p>Node.js Application deployed via GitHub Actions</p>
                </div>
                
                <div class="success">
                    ✅ Application is running successfully!
                </div>
                
                <div class="info">
                    <h3>System Information</h3>
                    <p><strong>Node.js Version:</strong> \${process.version}</p>
                    <p><strong>Environment:</strong> \${process.env.NODE_ENV || 'development'}</p>
                    <p><strong>Timestamp:</strong> \${new Date().toISOString()}</p>
                </div>
                
                <div class="info">
                    <h3>API Endpoints</h3>
                    <p><a href="/api/health">Health Check</a></p>
                    <p><a href="/api/info">System Info</a></p>
                </div>
            </div>
        </body>
        </html>
    \`);
});

app.get('/api/health', (req, res) => {
    res.json({
        status: 'healthy',
        timestamp: new Date().toISOString(),
        uptime: process.uptime()
    });
});

app.get('/api/info', (req, res) => {
    res.json({
        status: 'success',
        message: '${app_name} Node.js Application',
        version: '1.0.0',
        node_version: process.version,
        environment: process.env.NODE_ENV || 'development',
        timestamp: new Date().toISOString()
    });
});

app.listen(PORT, () => {
    console.log(\`🚀 ${app_name} server running on port \${PORT}\`);
    console.log(\`📍 Environment: \${process.env.NODE_ENV || 'development'}\`);
});
EOF
            ;;
        
        "python")
            # Create Python Flask application similar to existing examples
            cat > "example-${app_type}-app/requirements.txt" << 'REQ_EOF'
Flask==3.0.0
gunicorn==21.2.0
flask-cors==4.0.0
REQ_EOF
            
            cat > "example-${app_type}-app/app.py" << EOF
from flask import Flask, jsonify, render_template_string
from flask_cors import CORS
from datetime import datetime
import os

app = Flask(__name__)
CORS(app)

# HTML template
HTML_TEMPLATE = '''
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${app_name}</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; background: #f5f5f5; }
        .container { max-width: 800px; margin: 0 auto; background: white; padding: 30px; border-radius: 10px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        .header { text-align: center; color: #333; margin-bottom: 30px; }
        .info { background: #e8f4fd; padding: 15px; border-radius: 5px; margin: 15px 0; }
        .success { background: #d4edda; color: #155724; padding: 15px; border-radius: 5px; margin: 15px 0; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🚀 ${app_name}</h1>
            <p>Python Flask Application deployed via GitHub Actions</p>
        </div>
        
        <div class="success">
            ✅ Application is running successfully!
        </div>
        
        <div class="info">
            <h3>System Information</h3>
            <p><strong>Python Version:</strong> {{ python_version }}</p>
            <p><strong>Flask Version:</strong> {{ flask_version }}</p>
            <p><strong>Environment:</strong> {{ environment }}</p>
            <p><strong>Timestamp:</strong> {{ timestamp }}</p>
        </div>
        
        <div class="info">
            <h3>API Endpoints</h3>
            <p><a href="/api/health">Health Check</a></p>
            <p><a href="/api/info">System Info</a></p>
        </div>
    </div>
</body>
</html>
'''

@app.route('/')
def home():
    import sys
    import flask
    return render_template_string(HTML_TEMPLATE,
        python_version=sys.version.split()[0],
        flask_version=flask.__version__,
        environment=os.environ.get('FLASK_ENV', 'development'),
        timestamp=datetime.now().isoformat()
    )

@app.route('/api/health')
def health():
    return jsonify({
        'status': 'healthy',
        'timestamp': datetime.now().isoformat()
    })

@app.route('/api/info')
def info():
    import sys
    return jsonify({
        'status': 'success',
        'message': '${app_name} Python Flask Application',
        'version': '1.0.0',
        'python_version': sys.version.split()[0],
        'environment': os.environ.get('FLASK_ENV', 'development'),
        'timestamp': datetime.now().isoformat()
    })

if __name__ == '__main__':
    port = int(os.environ.get('PORT', 5000))
    debug = os.environ.get('FLASK_ENV') == 'development'
    app.run(host='0.0.0.0', port=port, debug=debug)
EOF
            ;;
        
        "react")
            # Create React application similar to existing examples
            local app_name_lower=$(to_lowercase "${app_name}")
            cat > "example-${app_type}-app/package.json" << EOF
{
  "name": "${app_name_lower}",
  "version": "1.0.0",
  "private": true,
  "dependencies": {
    "react": "^18.2.0",
    "react-dom": "^18.2.0",
    "react-scripts": "5.0.1"
  },
  "scripts": {
    "start": "react-scripts start",
    "build": "react-scripts build",
    "test": "react-scripts test --passWithNoTests",
    "eject": "react-scripts eject"
  },
  "eslintConfig": {
    "extends": [
      "react-app",
      "react-app/jest"
    ]
  },
  "browserslist": {
    "production": [
      ">0.2%",
      "not dead",
      "not op_mini all"
    ],
    "development": [
      "last 1 chrome version",
      "last 1 firefox version",
      "last 1 safari version"
    ]
  }
}
EOF
            
            mkdir -p "example-${app_type}-app/public"
            mkdir -p "example-${app_type}-app/src"
            
            cat > "example-${app_type}-app/public/index.html" << EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <meta name="theme-color" content="#000000" />
    <meta name="description" content="${app_name} React Application" />
    <title>${app_name}</title>
</head>
<body>
    <noscript>You need to enable JavaScript to run this app.</noscript>
    <div id="root"></div>
</body>
</html>
EOF
            
            cat > "example-${app_type}-app/src/index.js" << 'JS_EOF'
import React from 'react';
import ReactDOM from 'react-dom/client';
import './index.css';
import App from './App';

const root = ReactDOM.createRoot(document.getElementById('root'));
root.render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);
JS_EOF
            
            cat > "example-${app_type}-app/src/App.js" << EOF
import React, { useState, useEffect } from 'react';
import './App.css';

function App() {
  const [currentTime, setCurrentTime] = useState(new Date());

  useEffect(() => {
    const timer = setInterval(() => {
      setCurrentTime(new Date());
    }, 1000);

    return () => clearInterval(timer);
  }, []);

  return (
    <div className="App">
      <header className="App-header">
        <h1>🚀 ${app_name}</h1>
        <p>React Application deployed via GitHub Actions</p>
        
        <div className="success-message">
          ✅ Application is running successfully!
        </div>
        
        <div className="info-section">
          <h3>System Information</h3>
          <p><strong>React Version:</strong> {React.version}</p>
          <p><strong>Environment:</strong> {process.env.NODE_ENV}</p>
          <p><strong>Build Time:</strong> {process.env.REACT_APP_BUILD_TIME || 'Not set'}</p>
          <p><strong>Current Time:</strong> {currentTime.toLocaleString()}</p>
        </div>
        
        <div className="info-section">
          <h3>Features</h3>
          <ul>
            <li>Single Page Application (SPA)</li>
            <li>Production Build Optimization</li>
            <li>Static File Serving</li>
            <li>Responsive Design</li>
          </ul>
        </div>
      </header>
    </div>
  );
}

export default App;
EOF

            cat > "example-${app_type}-app/src/App.css" << 'CSS_EOF'
.App {
  text-align: center;
}

.App-header {
  background-color: #282c34;
  padding: 40px;
  color: white;
  min-height: 100vh;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  font-size: calc(10px + 2vmin);
}

.success-message {
  background-color: #d4edda;
  color: #155724;
  padding: 15px;
  border-radius: 5px;
  margin: 20px 0;
  font-size: 16px;
}

.info-section {
  background-color: rgba(255, 255, 255, 0.1);
  padding: 20px;
  border-radius: 10px;
  margin: 20px 0;
  max-width: 600px;
}

.info-section h3 {
  margin-top: 0;
  color: #61dafb;
}

.info-section p, .info-section li {
  font-size: 14px;
  text-align: left;
}

.info-section ul {
  text-align: left;
}
CSS_EOF

            cat > "example-${app_type}-app/src/index.css" << 'CSS_EOF'
body {
  margin: 0;
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', 'Roboto', 'Oxygen',
    'Ubuntu', 'Cantarell', 'Fira Sans', 'Droid Sans', 'Helvetica Neue',
    sans-serif;
  -webkit-font-smoothing: antialiased;
  -moz-osx-font-smoothing: grayscale;
}

code {
  font-family: source-code-pro, Menlo, Monaco, Consolas, 'Courier New',
    monospace;
}
CSS_EOF
            ;;
        
        "nginx")
            # Create static site similar to existing examples
            cat > "example-${app_type}-app/index.html" << EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${app_name}</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; background: #f5f5f5; }
        .container { max-width: 800px; margin: 0 auto; background: white; padding: 30px; border-radius: 10px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        .header { text-align: center; color: #333; margin-bottom: 30px; }
        .info { background: #e8f4fd; padding: 15px; border-radius: 5px; margin: 15px 0; }
        .success { background: #d4edda; color: #155724; padding: 15px; border-radius: 5px; margin: 15px 0; }
        .feature-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 20px; margin: 20px 0; }
        .feature-card { background: #f8f9fa; padding: 20px; border-radius: 8px; border-left: 4px solid #007bff; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🚀 ${app_name}</h1>
            <p>Nginx Static Site deployed via GitHub Actions</p>
        </div>
        
        <div class="success">
            ✅ Application is running successfully!
        </div>
        
        <div class="info">
            <h3>System Information</h3>
            <p><strong>Server:</strong> Nginx</p>
            <p><strong>Content Type:</strong> Static HTML/CSS/JS</p>
            <p><strong>Timestamp:</strong> <span id="timestamp"></span></p>
        </div>
        
        <div class="feature-grid">
            <div class="feature-card">
                <h4>🌐 Static Content</h4>
                <p>Fast, efficient static file serving with Nginx</p>
            </div>
            <div class="feature-card">
                <h4>📱 Responsive Design</h4>
                <p>Mobile-friendly responsive layout</p>
            </div>
            <div class="feature-card">
                <h4>⚡ High Performance</h4>
                <p>Optimized for speed and reliability</p>
            </div>
            <div class="feature-card">
                <h4>🔒 Secure</h4>
                <p>HTTPS ready with security headers</p>
            </div>
        </div>
    </div>
    
    <script>
        document.getElementById('timestamp').textContent = new Date().toLocaleString();
        
        // Update timestamp every second
        setInterval(() => {
            document.getElementById('timestamp').textContent = new Date().toLocaleString();
        }, 1000);
    </script>
</body>
</html>
EOF
            ;;
        
        "docker")
            # Create Docker application similar to existing examples
            cat > "example-${app_type}-app/docker-compose.yml" << EOF
version: '3.8'

services:
  web:
    build: .
    ports:
      - "80:80"
    environment:
      - APP_NAME=${app_name}
      - APP_ENV=production
    volumes:
      - ./html:/usr/share/nginx/html:ro
    restart: unless-stopped
    
  app:
    build:
      context: .
      dockerfile: Dockerfile.app
    environment:
      - APP_NAME=${app_name}
      - NODE_ENV=production
    restart: unless-stopped
    depends_on:
      - web

networks:
  default:
    name: $(to_lowercase "${app_name}")_network
EOF
            
            cat > "example-${app_type}-app/Dockerfile" << 'DOCKER_EOF'
FROM nginx:alpine

# Copy custom nginx config
COPY nginx.conf /etc/nginx/nginx.conf

# Copy static files
COPY html/ /usr/share/nginx/html/

# Create directory for logs
RUN mkdir -p /var/log/nginx

# Expose port 80
EXPOSE 80

# Start nginx
CMD ["nginx", "-g", "daemon off;"]
DOCKER_EOF

            cat > "example-${app_type}-app/Dockerfile.app" << 'DOCKER_EOF'
FROM node:18-alpine

WORKDIR /app

# Copy package files
COPY package*.json ./

# Install dependencies
RUN npm ci --only=production

# Copy application code
COPY app/ ./

# Create non-root user
RUN addgroup -g 1001 -S nodejs
RUN adduser -S nodejs -u 1001

# Change ownership
RUN chown -R nodejs:nodejs /app
USER nodejs

# Expose port
EXPOSE 3000

# Start application
CMD ["node", "index.js"]
DOCKER_EOF

            mkdir -p "example-${app_type}-app/html"
            cat > "example-${app_type}-app/html/index.html" << EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${app_name}</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; background: #f5f5f5; }
        .container { max-width: 800px; margin: 0 auto; background: white; padding: 30px; border-radius: 10px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        .header { text-align: center; color: #333; margin-bottom: 30px; }
        .info { background: #e8f4fd; padding: 15px; border-radius: 5px; margin: 15px 0; }
        .success { background: #d4edda; color: #155724; padding: 15px; border-radius: 5px; margin: 15px 0; }
        .docker-info { background: #0db7ed; color: white; padding: 20px; border-radius: 8px; margin: 20px 0; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🚀 ${app_name}</h1>
            <p>Docker Application deployed via GitHub Actions</p>
        </div>
        
        <div class="success">
            ✅ Application is running successfully!
        </div>
        
        <div class="docker-info">
            <h3>🐳 Docker Configuration</h3>
            <p><strong>Container:</strong> Multi-container setup with Docker Compose</p>
            <p><strong>Web Server:</strong> Nginx (Alpine Linux)</p>
            <p><strong>Application:</strong> Node.js backend service</p>
            <p><strong>Network:</strong> Custom Docker network</p>
        </div>
        
        <div class="info">
            <h3>System Information</h3>
            <p><strong>Deployment:</strong> Docker Compose</p>
            <p><strong>Environment:</strong> Production</p>
            <p><strong>Timestamp:</strong> <span id="timestamp"></span></p>
        </div>
    </div>
    
    <script>
        document.getElementById('timestamp').textContent = new Date().toLocaleString();
        setInterval(() => {
            document.getElementById('timestamp').textContent = new Date().toLocaleString();
        }, 1000);
    </script>
</body>
</html>
EOF

            cat > "example-${app_type}-app/nginx.conf" << 'NGINX_EOF'
events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    
    sendfile        on;
    keepalive_timeout  65;
    
    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;
    
    server {
        listen       80;
        server_name  localhost;
        
        location / {
            root   /usr/share/nginx/html;
            index  index.html index.htm;
            try_files $uri $uri/ /index.html;
        }
        
        # Security headers
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-XSS-Protection "1; mode=block" always;
        add_header X-Content-Type-Options "nosniff" always;
        
        error_page   500 502 503 504  /50x.html;
        location = /50x.html {
            root   /usr/share/nginx/html;
        }
    }
}
NGINX_EOF

            mkdir -p "example-${app_type}-app/app"
            local app_name_lower=$(to_lowercase "${app_name}")
            cat > "example-${app_type}-app/package.json" << EOF
{
  "name": "${app_name_lower}-backend",
  "version": "1.0.0",
  "description": "${app_name} Docker backend service",
  "main": "index.js",
  "scripts": {
    "start": "node index.js"
  },
  "dependencies": {
    "express": "^4.18.2"
  }
}
EOF

            cat > "example-${app_type}-app/app/index.js" << EOF
const express = require('express');
const app = express();
const PORT = process.env.PORT || 3000;

app.get('/api/health', (req, res) => {
    res.json({
        status: 'healthy',
        service: '${app_name} Backend',
        timestamp: new Date().toISOString()
    });
});

app.listen(PORT, () => {
    console.log(\`🚀 ${app_name} backend service running on port \${PORT}\`);
});
EOF
            ;;
    esac
    
    echo -e "${GREEN}✓ Created example-${app_type}-app/${NC}"
}

# Function to get user input with default value
get_input() {
    local prompt="$1"
    local default="$2"
    local value
    
    if [[ "$AUTO_MODE" == "true" ]]; then
        echo "$default"
        return
    fi
    
    read -p "$prompt [$default]: " value
    echo "${value:-$default}"
}

# Function to get yes/no input
get_yes_no() {
    local prompt="$1"
    local default="$2"
    local value
    
    if [[ "$AUTO_MODE" == "true" ]]; then
        echo "$default"
        return
    fi
    
    while true; do
        read -p "$prompt (y/n) [$default]: " value
        value="${value:-$default}"
        case $value in
            [Yy]* ) echo "true"; break;;
            [Nn]* ) echo "false"; break;;
            * ) echo "Please answer yes or no.";;
        esac
    done
}

# Function to select from options
select_option() {
    local prompt="$1"
    local default="$2"
    shift 2
    local options=("$@")
    
    if [[ "$AUTO_MODE" == "true" ]]; then
        echo "$default"
        return
    fi
    
    # Use /dev/tty for direct terminal interaction
    exec 3</dev/tty
    
    # Display menu to terminal
    echo "" > /dev/tty
    echo "$prompt" > /dev/tty
    for i in "${!options[@]}"; do
        echo "  $((i+1)). ${options[i]}" > /dev/tty
    done
    echo "" > /dev/tty
    
    while true; do
        echo -n "Select option [1-${#options[@]}] [$default]: " > /dev/tty
        read -u 3 choice
        choice="${choice:-$default}"
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ]; then
            echo "${options[$((choice-1))]}"
            break
        else
            echo "Invalid choice. Please select 1-${#options[@]}." > /dev/tty
        fi
    done
    
    exec 3<&-
}

# Function to setup GitHub OIDC if needed
setup_github_oidc() {
    local github_repo="$1"
    local aws_account_id="$2"
    
    echo -e "${BLUE}Setting up GitHub OIDC...${NC}"
    
    # Check if OIDC provider exists
    if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "arn:aws:iam::${aws_account_id}:oidc-provider/token.actions.githubusercontent.com" &> /dev/null; then
        echo -e "${BLUE}Creating GitHub OIDC provider...${NC}"
        
        # Get GitHub's OIDC thumbprint
        THUMBPRINT="6938fd4d98bab03faadb97b34396831e3780aea1"
        
        aws iam create-open-id-connect-provider \
            --url "https://token.actions.githubusercontent.com" \
            --client-id-list "sts.amazonaws.com" \
            --thumbprint-list "$THUMBPRINT" &> /dev/null
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ GitHub OIDC provider created${NC}"
        else
            echo -e "${YELLOW}⚠️  OIDC provider might already exist${NC}"
        fi
    else
        echo -e "${GREEN}✓ GitHub OIDC provider already exists${NC}"
    fi
}

# Function to commit and push changes
commit_and_push() {
    local app_type="$1"
    local app_name="$2"
    
    echo -e "${BLUE}Committing and pushing changes...${NC}"
    
    # Add all files
    git add .
    
    # Commit changes
    git commit -m "Add ${app_name} deployment configuration

- Added deployment-${app_type}.config.yml
- Added .github/workflows/deploy-${app_type}.yml  
- Added example-${app_type}-app/ with sample application
- Configured for AWS Lightsail deployment via GitHub Actions

Generated by setup-complete-deployment.sh"
    
    # Push to GitHub
    if git push origin main; then
        echo -e "${GREEN}✓ Changes pushed to GitHub${NC}"
        return 0
    elif git push origin master; then
        echo -e "${GREEN}✓ Changes pushed to GitHub${NC}"
        return 0
    else
        echo -e "${RED}❌ Failed to push changes${NC}"
        return 1
    fi
}

# Function to validate generated configuration
validate_configuration() {
    local app_type="$1"
    local config_file="deployment-${app_type}.config.yml"
    local workflow_file=".github/workflows/deploy-${app_type}.yml"
    
    echo -e "${BLUE}Validating generated configuration...${NC}"
    
    # Check if files exist
    if [[ ! -f "$config_file" ]]; then
        echo -e "${RED}❌ Configuration file not found: $config_file${NC}"
        return 1
    fi
    
    if [[ ! -f "$workflow_file" ]]; then
        echo -e "${RED}❌ Workflow file not found: $workflow_file${NC}"
        return 1
    fi
    
    # Validate YAML syntax
    if command -v python3 &> /dev/null; then
        python3 -c "import yaml; yaml.safe_load(open('$config_file'))" 2>/dev/null
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ Configuration YAML is valid${NC}"
        else
            echo -e "${RED}❌ Configuration YAML is invalid${NC}"
            return 1
        fi
        
        python3 -c "import yaml; yaml.safe_load(open('$workflow_file'))" 2>/dev/null
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ Workflow YAML is valid${NC}"
        else
            echo -e "${RED}❌ Workflow YAML is invalid${NC}"
            return 1
        fi
    fi
    
    # Check for required sections in config
    local required_sections=("aws" "lightsail" "application" "dependencies" "deployment" "github_actions" "monitoring")
    for section in "${required_sections[@]}"; do
        if grep -q "^${section}:" "$config_file"; then
            echo -e "${GREEN}✓ Found required section: $section${NC}"
        else
            echo -e "${YELLOW}⚠️  Missing section: $section${NC}"
        fi
    done
    
    # Check workflow uses reusable workflow
    if grep -q "uses: ./.github/workflows/deploy-generic-reusable.yml" "$workflow_file"; then
        echo -e "${GREEN}✓ Workflow uses reusable deployment${NC}"
    else
        echo -e "${RED}❌ Workflow doesn't use reusable deployment${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✓ Configuration validation passed${NC}"
    return 0
}

# Function to display final instructions
show_final_instructions() {
    local app_type="$1"
    local app_name="$2"
    local instance_name="$3"
    local github_repo="$4"
    
    echo ""
    echo -e "${GREEN}🎉 Setup Complete! ${NC}"
    echo ""
    echo -e "${BLUE}Your ${app_name} deployment is ready!${NC}"
    echo ""
    echo "📁 Files created:"
    echo "  - deployment-${app_type}.config.yml"
    echo "  - .github/workflows/deploy-${app_type}.yml"
    echo "  - example-${app_type}-app/ (sample application)"
    echo ""
    echo "🚀 Next steps:"
    echo "  1. Review and customize the configuration files"
    echo "  2. Update default passwords in deployment-${app_type}.config.yml"
    echo "  3. Push changes to trigger deployment: git push origin main"
    echo "  4. Monitor deployment at: https://github.com/${github_repo}/actions"
    echo ""
    echo "🌐 After deployment:"
    echo "  - Your app will be available at: http://${instance_name}.lightsail.aws.com/"
    echo "  - Check GitHub Actions for deployment status and IP address"
    echo ""
    echo -e "${YELLOW}⚠️  Important:${NC}"
    echo "  - Change default passwords in the config file before deploying"
    echo "  - Ensure AWS_ROLE_ARN is set in GitHub repository secrets/variables"
    echo "  - Review security settings and firewall configuration"
    echo ""
}

# Main execution function
main() {
    echo -e "${BLUE}🚀 Complete Deployment Setup Script${NC}"
    echo -e "${BLUE}====================================${NC}"
    echo ""
    
    # Check prerequisites
    check_prerequisites
    
    # Check if we're in a git repository
    if ! check_git_repo; then
        echo -e "${RED}❌ Not in a git repository${NC}"
        echo "Please run this script from within a git repository."
        exit 1
    fi
    
    # Get AWS account ID
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    if [ -z "$AWS_ACCOUNT_ID" ]; then
        echo -e "${RED}❌ Failed to get AWS account ID${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ AWS Account ID: $AWS_ACCOUNT_ID${NC}"
    
    # Get GitHub repository info
    if [[ "$FULLY_AUTOMATED" == "true" && -n "$GITHUB_REPO" ]]; then
        echo -e "${GREEN}✓ Using GITHUB_REPO: $GITHUB_REPO${NC}"
    else
        # Try to get from git remote or use environment variable as fallback
        if [[ -z "$GITHUB_REPO" ]]; then
            GITHUB_REPO=$(git remote get-url origin 2>/dev/null | sed 's/.*github\.com[:/]\([^/]*\/[^/]*\)\.git.*/\1/' | sed 's/\.git$//')
        fi
        
        if [ -z "$GITHUB_REPO" ]; then
            if [[ "$FULLY_AUTOMATED" == "true" ]]; then
                # Use app name as repository name for fully automated mode
                GITHUB_REPO="$APP_NAME"
                echo -e "${GREEN}✓ Using repository name: $GITHUB_REPO${NC}"
            else
                echo -e "${RED}❌ Failed to determine GitHub repository${NC}"
                exit 1
            fi
        else
            echo -e "${GREEN}✓ GitHub Repository: $GITHUB_REPO${NC}"
        fi
    fi
    echo ""
    
    # Check if we're in fully automated mode (all required env vars set)
    FULLY_AUTOMATED=false
    if [[ -n "$APP_TYPE" && -n "$APP_NAME" && -n "$INSTANCE_NAME" ]]; then
        FULLY_AUTOMATED=true
        echo -e "${GREEN}✓ Running in fully automated mode${NC}"
        echo -e "${BLUE}Configuration from environment variables:${NC}"
        echo "  App Type: $APP_TYPE"
        echo "  App Name: $APP_NAME"
        echo "  Instance: $INSTANCE_NAME"
        echo "  Region: $AWS_REGION"
        echo "  OS: $BLUEPRINT_ID"
        echo "  Bundle: $BUNDLE_ID"
        echo "  Database: $DATABASE_TYPE"
        echo "  Bucket: $ENABLE_BUCKET"
        echo ""
    fi
    
    # Application type selection
    if [[ "$FULLY_AUTOMATED" == "true" ]]; then
        # Validate app type
        if [[ ! "$APP_TYPE" =~ ^(lamp|nodejs|python|react|docker|nginx)$ ]]; then
            echo -e "${RED}❌ Invalid APP_TYPE: $APP_TYPE. Must be one of: lamp, nodejs, python, react, docker, nginx${NC}"
            exit 1
        fi
        echo -e "${GREEN}✓ Using APP_TYPE: $APP_TYPE${NC}"
    else
        APP_TYPES=("lamp" "nodejs" "python" "react" "docker" "nginx")
        APP_TYPE=$(select_option "Choose application type:" "1" "${APP_TYPES[@]}")
    fi
    
    # Application name
    if [[ "$FULLY_AUTOMATED" != "true" ]]; then
        APP_NAME=$(get_input "Enter application name" "$(to_uppercase "${APP_TYPE:0:1}")${APP_TYPE:1} Application")
    fi
    
    # Instance configuration
    if [[ "$FULLY_AUTOMATED" != "true" ]]; then
        INSTANCE_NAME=$(get_input "Enter Lightsail instance name" "${APP_TYPE}-app-$(date +%s)")
    fi
    
    # AWS Region
    if [[ "$FULLY_AUTOMATED" != "true" ]]; then
        AWS_REGION=$(get_input "Enter AWS region" "$AWS_REGION")
    fi
    
    # Instance size
    if [[ "$FULLY_AUTOMATED" == "true" ]]; then
        # Validate bundle for Docker
        if [[ "$APP_TYPE" == "docker" && "$BUNDLE_ID" =~ ^(nano_3_0|micro_3_0)$ ]]; then
            echo -e "${RED}❌ Docker applications require minimum small_3_0 bundle (2GB RAM). Current: $BUNDLE_ID${NC}"
            exit 1
        fi
        echo -e "${GREEN}✓ Using BUNDLE_ID: $BUNDLE_ID${NC}"
    else
        if [[ "$APP_TYPE" == "docker" ]]; then
            BUNDLES=("small_3_0" "medium_3_0" "large_3_0")
            BUNDLE_ID=$(select_option "Choose bundle (Docker needs minimum 2GB):" "2" "${BUNDLES[@]}")
        else
            BUNDLES=("nano_3_0" "micro_3_0" "small_3_0" "medium_3_0")
            BUNDLE_ID=$(select_option "Choose bundle:" "2" "${BUNDLES[@]}")
        fi
    fi
    
    # Operating system
    if [[ "$FULLY_AUTOMATED" == "true" ]]; then
        # Validate blueprint
        if [[ ! "$BLUEPRINT_ID" =~ ^(ubuntu_22_04|ubuntu_20_04|amazon_linux_2023)$ ]]; then
            echo -e "${RED}❌ Invalid BLUEPRINT_ID: $BLUEPRINT_ID. Must be one of: ubuntu_22_04, ubuntu_20_04, amazon_linux_2023${NC}"
            exit 1
        fi
        echo -e "${GREEN}✓ Using BLUEPRINT_ID: $BLUEPRINT_ID${NC}"
    else
        BLUEPRINTS=("ubuntu_22_04" "ubuntu_20_04" "amazon_linux_2023")
        BLUEPRINT_ID=$(select_option "Choose OS:" "1" "${BLUEPRINTS[@]}")
    fi
    
    # Database configuration
    if [[ "$FULLY_AUTOMATED" == "true" ]]; then
        # Use environment variables
        DB_TYPE="$DATABASE_TYPE"
        # Validate database type
        if [[ ! "$DB_TYPE" =~ ^(mysql|postgresql|none)$ ]]; then
            echo -e "${RED}❌ Invalid DATABASE_TYPE: $DB_TYPE. Must be one of: mysql, postgresql, none${NC}"
            exit 1
        fi
        echo -e "${GREEN}✓ Using DATABASE_TYPE: $DB_TYPE${NC}"
        
        if [[ "$DB_TYPE" != "none" ]]; then
            if [[ "$DB_EXTERNAL" == "true" && -z "$DB_RDS_NAME" ]]; then
                DB_RDS_NAME="${APP_TYPE}-${DB_TYPE}-db"
            fi
        fi
    else
        # Interactive mode
        DB_TYPE="none"
        DB_EXTERNAL="false"
        DB_RDS_NAME=""
        DB_NAME="app_db"
        
        # Database configuration (available for all application types)
        DB_TYPES=("mysql" "postgresql" "none")
        DB_TYPE=$(select_option "Choose database type:" "3" "${DB_TYPES[@]}")
        
        if [[ "$DB_TYPE" != "none" ]]; then
            DB_EXTERNAL=$(get_yes_no "Use external RDS database?" "false")
            if [[ "$DB_EXTERNAL" == "true" ]]; then
                DB_RDS_NAME=$(get_input "Enter RDS instance name" "${APP_TYPE}-${DB_TYPE}-db")
            fi
            DB_NAME=$(get_input "Enter database name" "app_db")
        fi
    fi
    
    # Bucket configuration
    if [[ "$FULLY_AUTOMATED" == "true" ]]; then
        # Use environment variables
        if [[ "$ENABLE_BUCKET" == "true" && -z "$BUCKET_NAME" ]]; then
            BUCKET_NAME="${APP_TYPE}-bucket-$(date +%s)"
        fi
        # Validate bucket access
        if [[ "$ENABLE_BUCKET" == "true" && ! "$BUCKET_ACCESS" =~ ^(read_only|read_write)$ ]]; then
            echo -e "${RED}❌ Invalid BUCKET_ACCESS: $BUCKET_ACCESS. Must be one of: read_only, read_write${NC}"
            exit 1
        fi
        # Validate bucket bundle
        if [[ "$ENABLE_BUCKET" == "true" && ! "$BUCKET_BUNDLE" =~ ^(small_1_0|medium_1_0|large_1_0)$ ]]; then
            echo -e "${RED}❌ Invalid BUCKET_BUNDLE: $BUCKET_BUNDLE. Must be one of: small_1_0, medium_1_0, large_1_0${NC}"
            exit 1
        fi
        echo -e "${GREEN}✓ Using ENABLE_BUCKET: $ENABLE_BUCKET${NC}"
    else
        # Interactive mode
        ENABLE_BUCKET=$(get_yes_no "Enable Lightsail bucket?" "false")
        BUCKET_NAME=""
        BUCKET_ACCESS="read_write"
        BUCKET_BUNDLE="small_1_0"
        
        if [[ "$ENABLE_BUCKET" == "true" ]]; then
            BUCKET_NAME=$(get_input "Enter bucket name" "${APP_TYPE}-bucket-$(date +%s)")
            BUCKET_ACCESSES=("read_only" "read_write")
            BUCKET_ACCESS=$(select_option "Choose bucket access level:" "2" "${BUCKET_ACCESSES[@]}")
            
            BUCKET_BUNDLES=("small_1_0" "medium_1_0" "large_1_0")
            BUCKET_BUNDLE=$(select_option "Choose bucket size:" "1" "${BUCKET_BUNDLES[@]}")
        fi
    fi
    
    echo ""
    echo -e "${BLUE}Creating deployment configuration...${NC}"
    
    # Setup workflow files first
    setup_workflow_files
    
    # Create deployment configuration
    create_deployment_config "$APP_TYPE" "$APP_NAME" "$INSTANCE_NAME" "$AWS_REGION" \
        "$BLUEPRINT_ID" "$BUNDLE_ID" "$DB_TYPE" "$DB_EXTERNAL" "$DB_RDS_NAME" \
        "$DB_NAME" "$BUCKET_NAME" "$BUCKET_ACCESS" "$BUCKET_BUNDLE" "$ENABLE_BUCKET"
    
    # Create GitHub workflow
    create_github_workflow "$APP_TYPE" "$APP_NAME" "$AWS_REGION"
    
    # Create example application
    create_example_app "$APP_TYPE" "$APP_NAME"
    
    # Validate generated configuration
    if ! validate_configuration "$APP_TYPE"; then
        echo -e "${RED}❌ Configuration validation failed${NC}"
        exit 1
    fi
    
    # Setup GitHub OIDC
    setup_github_oidc "$GITHUB_REPO" "$AWS_ACCOUNT_ID"
    
    # Create IAM role
    ROLE_NAME="GitHubActions-${APP_TYPE}-deployment"
    create_iam_role_if_needed "$ROLE_NAME" "$GITHUB_REPO" "$AWS_ACCOUNT_ID"
    
    echo ""
    echo -e "${BLUE}Setting up GitHub repository secrets...${NC}"
    
    # Check if AWS_ROLE_ARN is already set
    if ! gh variable list | grep -q "AWS_ROLE_ARN"; then
        if ! gh secret list | grep -q "AWS_ROLE_ARN"; then
            echo -e "${YELLOW}Setting AWS_ROLE_ARN as repository variable...${NC}"
            gh variable set AWS_ROLE_ARN --body "$AWS_ROLE_ARN"
            echo -e "${GREEN}✓ AWS_ROLE_ARN variable set${NC}"
        else
            echo -e "${GREEN}✓ AWS_ROLE_ARN secret already exists${NC}"
        fi
    else
        echo -e "${GREEN}✓ AWS_ROLE_ARN variable already exists${NC}"
    fi
    
    # Commit and push changes
    if commit_and_push "$APP_TYPE" "$APP_NAME"; then
        echo ""
        echo -e "${GREEN}✅ Deployment triggered!${NC}"
        echo -e "${BLUE}Monitor progress at: https://github.com/${GITHUB_REPO}/actions${NC}"
    fi
    
    # Show final instructions
    show_final_instructions "$APP_TYPE" "$APP_NAME" "$INSTANCE_NAME" "$GITHUB_REPO"
}

# Function to show help
show_help() {
    cat << EOF
🚀 Complete Deployment Setup Script
===================================

This script sets up automated deployment for various application types on AWS Lightsail
using GitHub Actions. It creates deployment configurations, workflows, and example applications
that match the existing working patterns in this repository.

USAGE:
    $0 [OPTIONS]

OPTIONS:
    --auto              Run in automatic mode (uses defaults, no prompts)
    --aws-region REGION Set AWS region (default: us-east-1)
    --app-version VER   Set application version (default: 1.0.0)
    --help, -h          Show this help message

ENVIRONMENT VARIABLES:
    AUTO_MODE           Set to 'true' for automatic mode
    AWS_REGION          AWS region to use
    APP_VERSION         Application version

SUPPORTED APPLICATION TYPES:
    - lamp              LAMP stack (Linux, Apache, MySQL, PHP)
    - nodejs            Node.js with Express
    - python            Python with Flask
    - react             React single-page application
    - docker            Docker multi-container application
    - nginx             Static site with Nginx

PREREQUISITES:
    - git               Version control
    - gh                GitHub CLI (authenticated)
    - aws               AWS CLI (configured)
    - Active GitHub repository with proper permissions

EXAMPLES:
    # Interactive mode (default)
    $0

    # Automatic mode with defaults
    AUTO_MODE=true $0

    # Specify region
    $0 --aws-region us-west-2

    # Full automatic setup
    $0 --auto --aws-region eu-west-1 --app-version 2.0.0

WHAT IT CREATES:
    - deployment-{type}.config.yml    Deployment configuration
    - .github/workflows/deploy-{type}.yml    GitHub Actions workflow
    - example-{type}-app/             Sample application
    - AWS IAM role for GitHub OIDC    (if needed)
    - GitHub repository variables     (AWS_ROLE_ARN)

The generated configurations match the existing working examples in this repository
and are compatible with the deploy-generic-reusable.yml workflow.

For more information, see: https://github.com/naveenraj44125-creator/lamp-stack-lightsail
EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --auto)
                AUTO_MODE=true
                shift
                ;;
            --aws-region)
                AWS_REGION="$2"
                shift 2
                ;;
            --app-version)
                APP_VERSION="$2"
                shift 2
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    parse_args "$@"
    main
fi