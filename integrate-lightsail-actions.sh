#!/bin/bash
# Integrate Lightsail GitHub Actions into Existing Repository
# This script adds deployment automation to your existing GitHub repository

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Lightsail GitHub Actions Integration Script              ║${NC}"
echo -e "${BLUE}║  Add automated deployment to your existing repository      ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Function to run automated prerequisites setup
run_prerequisites_setup() {
    echo -e "${BLUE}Checking if automated prerequisites setup is available...${NC}"
    
    if [[ -f "setup-prerequisites.sh" ]]; then
        echo -e "${GREEN}✓ Found setup-prerequisites.sh${NC}"
        echo ""
        echo -e "${YELLOW}This script can automatically install missing prerequisites (Git, GitHub CLI, AWS CLI, Node.js)${NC}"
        echo -e "${YELLOW}and configure authentication for GitHub and AWS.${NC}"
        echo ""
        read -p "Run automated prerequisites setup? (Y/n): " -n 1 -r
        echo
        
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            echo ""
            echo -e "${BLUE}Running automated prerequisites setup...${NC}"
            echo ""
            
            if bash setup-prerequisites.sh; then
                echo ""
                echo -e "${GREEN}✅ Automated prerequisites setup completed successfully!${NC}"
                echo ""
                return 0
            else
                echo ""
                echo -e "${YELLOW}⚠️  Automated prerequisites setup encountered issues.${NC}"
                echo -e "${YELLOW}Continuing with manual prerequisites checking...${NC}"
                echo ""
                return 1
            fi
        else
            echo ""
            echo -e "${BLUE}Skipping automated setup, proceeding with manual prerequisites checking...${NC}"
            echo ""
            return 1
        fi
    else
        echo -e "${YELLOW}⚠️  setup-prerequisites.sh not found in current directory${NC}"
        echo -e "${BLUE}Proceeding with manual prerequisites checking...${NC}"
        echo ""
        return 1
    fi
}

# Run automated prerequisites setup first
run_prerequisites_setup

# Enhanced Prerequisites Checking Function
check_prerequisites() {
    echo -e "${YELLOW}Checking prerequisites...${NC}"
    local all_good=true
    local missing_tools=()
    local setup_instructions=()

    # Check if we're in a git repository
    if [ ! -d ".git" ]; then
        echo -e "${RED}❌ Error: Not a git repository${NC}"
        echo "Please run this script from the root of your git repository"
        exit 1
    fi

    # Get repository information
    local repo_url=$(git config --get remote.origin.url || echo "")
    local current_branch=$(git branch --show-current)
    echo -e "${GREEN}✓ Git repository detected${NC}"
    echo "  Repository: $repo_url"
    echo "  Current branch: $current_branch"

    # Node.js check (only needed for Node.js/React apps)
    if command -v node &> /dev/null; then
        local node_version=$(node --version 2>/dev/null)
        echo -e "${GREEN}✓ Node.js found: ${node_version} (available for Node.js/React apps)${NC}"
    else
        echo -e "${BLUE}ℹ Node.js not found (only needed for Node.js/React applications)${NC}"
    fi

    # Git check (required)
    if command -v git &> /dev/null; then
        local git_version=$(git --version 2>/dev/null | cut -d' ' -f3)
        echo -e "${GREEN}✓ Git found: ${git_version}${NC}"
    else
        echo -e "${RED}✗ Git is not installed (REQUIRED)${NC}"
        missing_tools+=("git")
        setup_instructions+=("Git: Install from https://git-scm.com/ or use 'brew install git' (macOS)")
        all_good=false
    fi

    # GitHub CLI check (optional but recommended for OIDC setup)
    if command -v gh &> /dev/null; then
        local gh_version=$(gh --version 2>/dev/null | head -n1 | cut -d' ' -f3)
        echo -e "${GREEN}✓ GitHub CLI found: ${gh_version}${NC}"
        
        # Check GitHub CLI authentication
        if gh auth status &> /dev/null; then
            local gh_user=$(gh api user -q .login 2>/dev/null || echo "unknown")
            echo -e "${GREEN}✓ GitHub CLI authenticated as: ${gh_user}${NC}"
        else
            echo -e "${YELLOW}⚠ GitHub CLI not authenticated (recommended for OIDC setup)${NC}"
            setup_instructions+=("GitHub Auth: Run 'gh auth login' for automatic OIDC setup")
        fi
    else
        echo -e "${YELLOW}⚠ GitHub CLI not installed (recommended for OIDC setup)${NC}"
        setup_instructions+=("GitHub CLI: Install from https://cli.github.com/ or use 'brew install gh' (macOS)")
    fi

    # AWS CLI check (required for OIDC setup)
    if command -v aws &> /dev/null; then
        local aws_version=$(aws --version 2>/dev/null | cut -d' ' -f1 | cut -d'/' -f2)
        echo -e "${GREEN}✓ AWS CLI found: ${aws_version}${NC}"
        
        # Check AWS CLI configuration
        if aws sts get-caller-identity &> /dev/null; then
            local aws_account=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
            local aws_user=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null | cut -d'/' -f2)
            echo -e "${GREEN}✓ AWS CLI configured (Account: ${aws_account}, User: ${aws_user})${NC}"
        else
            echo -e "${YELLOW}⚠ AWS CLI not configured (required for OIDC setup)${NC}"
            setup_instructions+=("AWS Config: Run 'aws configure' or 'source .aws-creds.sh' if you have a credentials script")
        fi
    else
        echo -e "${YELLOW}⚠ AWS CLI not installed (required for OIDC setup)${NC}"
        setup_instructions+=("AWS CLI: Install from https://aws.amazon.com/cli/ or use 'brew install awscli' (macOS)")
    fi

    # Curl check (required for downloading files)
    if command -v curl &> /dev/null; then
        echo -e "${GREEN}✓ Curl found${NC}"
    else
        echo -e "${RED}✗ Curl not installed (REQUIRED for downloading workflow files)${NC}"
        missing_tools+=("curl")
        setup_instructions+=("Curl: Install using 'brew install curl' (macOS) or 'sudo apt install curl' (Ubuntu)")
        all_good=false
    fi

    # Shell environment check
    if [[ -n "$SHELL" ]]; then
        echo -e "${GREEN}✓ Shell environment: ${SHELL}${NC}"
    else
        echo -e "${YELLOW}⚠ Shell environment not properly set${NC}"
        setup_instructions+=("Shell: Ensure SHELL environment variable is set")
    fi

    # PATH check for common directories
    local path_dirs=("/usr/local/bin" "/opt/homebrew/bin" "/usr/bin" "/bin")
    local missing_paths=()
    for dir in "${path_dirs[@]}"; do
        if [[ ":$PATH:" != *":$dir:"* ]] && [[ -d "$dir" ]]; then
            missing_paths+=("$dir")
        fi
    done
    
    if [[ ${#missing_paths[@]} -eq 0 ]]; then
        echo -e "${GREEN}✓ PATH environment properly configured${NC}"
    else
        echo -e "${YELLOW}⚠ Some common directories missing from PATH: ${missing_paths[*]}${NC}"
        setup_instructions+=("PATH: Consider adding missing directories to your PATH environment variable")
    fi

    echo ""

    # Show setup instructions if there are issues
    if [[ ${#setup_instructions[@]} -gt 0 ]]; then
        echo -e "${BLUE}Setup Instructions:${NC}"
        for instruction in "${setup_instructions[@]}"; do
            echo -e "  ${YELLOW}•${NC} $instruction"
        done
        echo ""
    fi

    # Handle missing requirements
    if [[ "$all_good" != "true" ]]; then
        echo -e "${RED}❌ Missing required tools: ${missing_tools[*]}${NC}"
        echo ""
        echo -e "${YELLOW}Please install the missing requirements and run this script again.${NC}"
        echo ""
        echo -e "${BLUE}Quick Setup Commands:${NC}"
        
        # macOS setup
        if [[ "$OSTYPE" == "darwin"* ]]; then
            echo -e "${GREEN}macOS (using Homebrew):${NC}"
            [[ " ${missing_tools[*]} " =~ " git " ]] && echo "  brew install git"
            [[ " ${missing_tools[*]} " =~ " curl " ]] && echo "  brew install curl"
        fi
        
        # Ubuntu/Debian setup
        echo -e "${GREEN}Ubuntu/Debian:${NC}"
        [[ " ${missing_tools[*]} " =~ " git " ]] && echo "  sudo apt update && sudo apt install git"
        [[ " ${missing_tools[*]} " =~ " curl " ]] && echo "  sudo apt install curl"
        
        echo ""
        exit 1
    fi

    echo -e "${GREEN}✅ All prerequisites satisfied!${NC}"
    echo ""
}

# Helper function to attempt automatic fixes
attempt_auto_fixes() {
    echo -e "${BLUE}Attempting automatic fixes for common issues...${NC}"
    
    # Fix PATH if needed
    local path_updated=false
    local common_paths=("/usr/local/bin" "/opt/homebrew/bin")
    
    for dir in "${common_paths[@]}"; do
        if [[ ":$PATH:" != *":$dir:"* ]] && [[ -d "$dir" ]]; then
            export PATH="$PATH:$dir"
            path_updated=true
            echo -e "${GREEN}✓ Added $dir to PATH${NC}"
        fi
    done
    
    if [[ "$path_updated" == "true" ]]; then
        echo -e "${YELLOW}⚠ PATH updated for this session. Consider adding to your shell profile (.bashrc, .zshrc)${NC}"
    fi
    
    # Check if tools are now available after PATH update
    if [[ "$path_updated" == "true" ]]; then
        echo -e "${BLUE}Re-checking tools after PATH update...${NC}"
        
        if command -v gh &> /dev/null; then
            echo -e "${GREEN}✓ GitHub CLI now found${NC}"
        fi
        
        if command -v aws &> /dev/null; then
            echo -e "${GREEN}✓ AWS CLI now found${NC}"
        fi
        
        if command -v curl &> /dev/null; then
            echo -e "${GREEN}✓ Curl now found${NC}"
        fi
    fi
    
    echo ""
}

# Run prerequisites check
check_prerequisites

# Attempt automatic fixes if needed
attempt_auto_fixes

# Confirm with user
read -p "Do you want to integrate Lightsail deployment into this repository? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Integration cancelled."
    exit 0
fi

echo ""
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Step 1: Application Configuration${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo ""

# Application type selection
echo "Select your application type:"
echo "1) LAMP Stack (Apache + PHP + MySQL/PostgreSQL)"
echo "2) NGINX (Static sites or reverse proxy)"
echo "3) Node.js (Express, Next.js, etc.)"
echo "4) Python (Flask, Django, FastAPI)"
echo "5) React (Create React App, Vite, etc.)"
echo "6) Docker (Multi-container with Docker Compose)"
read -p "Enter choice (1-6): " APP_TYPE_CHOICE

case $APP_TYPE_CHOICE in
    1) APP_TYPE="lamp"; APP_TYPE_NAME="LAMP Stack";;
    2) APP_TYPE="nginx"; APP_TYPE_NAME="NGINX";;
    3) APP_TYPE="nodejs"; APP_TYPE_NAME="Node.js";;
    4) APP_TYPE="python"; APP_TYPE_NAME="Python";;
    5) APP_TYPE="react"; APP_TYPE_NAME="React";;
    6) APP_TYPE="docker"; APP_TYPE_NAME="Docker"
       echo ""
       echo -e "${YELLOW}Note: With Docker, all services run in containers (no direct installs on host)${NC}"
       ;;
    *) echo "Invalid choice"; exit 1;;
esac

echo -e "${GREEN}✓ Selected: $APP_TYPE_NAME${NC}"
echo ""

# Instance name
read -p "Enter Lightsail instance name (e.g., my-app-prod): " INSTANCE_NAME
if [ -z "$INSTANCE_NAME" ]; then
    echo -e "${RED}❌ Instance name is required${NC}"
    exit 1
fi

# AWS Region
echo ""
echo "Select AWS region:"
echo "1) us-east-1 (N. Virginia)"
echo "2) us-west-2 (Oregon)"
echo "3) eu-west-1 (Ireland)"
echo "4) ap-southeast-1 (Singapore)"
read -p "Enter choice (1-4) [default: 1]: " REGION_CHOICE
case ${REGION_CHOICE:-1} in
    1) AWS_REGION="us-east-1";;
    2) AWS_REGION="us-west-2";;
    3) AWS_REGION="eu-west-1";;
    4) AWS_REGION="ap-southeast-1";;
    *) AWS_REGION="us-east-1";;
esac

echo -e "${GREEN}✓ Region: $AWS_REGION${NC}"

# Instance Configuration
echo ""
echo "Select Operating System:"
echo "1) Ubuntu 22.04 LTS (Recommended)"
echo "2) Ubuntu 20.04 LTS"
echo "3) Amazon Linux 2023"
echo "4) Amazon Linux 2"
echo "5) CentOS 7"
read -p "Choose OS (1-5) [default: 1]: " OS_CHOICE
case ${OS_CHOICE:-1} in
    1) BLUEPRINT_ID="ubuntu_22_04"; OS_NAME="Ubuntu 22.04 LTS";;
    2) BLUEPRINT_ID="ubuntu_20_04"; OS_NAME="Ubuntu 20.04 LTS";;
    3) BLUEPRINT_ID="amazon_linux_2023"; OS_NAME="Amazon Linux 2023";;
    4) BLUEPRINT_ID="amazon_linux_2"; OS_NAME="Amazon Linux 2";;
    5) BLUEPRINT_ID="centos_7_2009_01"; OS_NAME="CentOS 7";;
    *) BLUEPRINT_ID="ubuntu_22_04"; OS_NAME="Ubuntu 22.04 LTS";;
esac

echo -e "${GREEN}✓ OS: $OS_NAME${NC}"

echo ""
echo "Select Instance Size:"
echo "1) Nano - 512MB RAM, 1 vCPU, 20GB SSD (Lightest workloads)"
echo "2) Micro - 1GB RAM, 1 vCPU, 40GB SSD (Small apps)"
echo "3) Small - 2GB RAM, 2 vCPU, 60GB SSD (Recommended for most apps)"
echo "4) Medium - 4GB RAM, 2 vCPU, 80GB SSD (High traffic apps)"
echo "5) Large - 8GB RAM, 4 vCPU, 160GB SSD (Resource intensive)"
echo "6) XLarge - 16GB RAM, 4 vCPU, 320GB SSD (Heavy workloads)"
echo "7) 2XLarge - 32GB RAM, 8 vCPU, 640GB SSD (Enterprise)"
read -p "Choose size (1-7) [default: 3]: " SIZE_CHOICE
case ${SIZE_CHOICE:-3} in
    1) BUNDLE_ID="nano_3_0"; SIZE_NAME="Nano (512MB)"; SIZE_COST="\$3.50/month";;
    2) BUNDLE_ID="micro_3_0"; SIZE_NAME="Micro (1GB)"; SIZE_COST="\$5/month";;
    3) BUNDLE_ID="small_3_0"; SIZE_NAME="Small (2GB)"; SIZE_COST="\$10/month";;
    4) BUNDLE_ID="medium_3_0"; SIZE_NAME="Medium (4GB)"; SIZE_COST="\$20/month";;
    5) BUNDLE_ID="large_3_0"; SIZE_NAME="Large (8GB)"; SIZE_COST="\$40/month";;
    6) BUNDLE_ID="xlarge_3_0"; SIZE_NAME="XLarge (16GB)"; SIZE_COST="\$80/month";;
    7) BUNDLE_ID="2xlarge_3_0"; SIZE_NAME="2XLarge (32GB)"; SIZE_COST="\$160/month";;
    *) BUNDLE_ID="small_3_0"; SIZE_NAME="Small (2GB)"; SIZE_COST="\$10/month";;
esac

echo -e "${GREEN}✓ Size: $SIZE_NAME ($SIZE_COST)${NC}"
echo ""

# Database configuration
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Step 2: Database Configuration${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo ""

if [[ "$APP_TYPE" == "lamp" ]] || [[ "$APP_TYPE" == "nodejs" ]] || [[ "$APP_TYPE" == "python" ]]; then
    echo "Do you need a database?"
    echo "1) No database"
    echo "2) MySQL (local or RDS)"
    echo "3) PostgreSQL (local or RDS)"
    read -p "Enter choice (1-3): " DB_CHOICE
    
    case $DB_CHOICE in
        1) DB_TYPE="none";;
        2) DB_TYPE="mysql";;
        3) DB_TYPE="postgresql";;
        *) DB_TYPE="none";;
    esac
    
    if [[ "$DB_TYPE" != "none" ]]; then
        read -p "Use external RDS database? (y/n) [default: n]: " USE_RDS
        if [[ "$USE_RDS" =~ ^[Yy]$ ]]; then
            DB_EXTERNAL="true"
            read -p "Enter RDS instance name: " DB_RDS_NAME
            read -p "Enter database name: " DB_NAME
        else
            DB_EXTERNAL="false"
            DB_RDS_NAME=""
            DB_NAME="app_db"
        fi
    fi
else
    DB_TYPE="none"
    DB_EXTERNAL="false"
fi

echo -e "${GREEN}✓ Database configured${NC}"
echo ""

# Bucket configuration
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Step 3: S3 Bucket Configuration${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo ""

read -p "Enable Lightsail bucket for file storage? (y/n) [default: n]: " ENABLE_BUCKET
if [[ "$ENABLE_BUCKET" =~ ^[Yy]$ ]]; then
    read -p "Enter bucket name: " BUCKET_NAME
    
    echo "Select bucket access level:"
    echo "1) read_only - Instance can only download files"
    echo "2) read_write - Instance can upload and download files"
    read -p "Enter choice (1-2) [default: 2]: " BUCKET_ACCESS_CHOICE
    case ${BUCKET_ACCESS_CHOICE:-2} in
        1) BUCKET_ACCESS="read_only";;
        2) BUCKET_ACCESS="read_write";;
        *) BUCKET_ACCESS="read_write";;
    esac
    
    echo "Select bucket size:"
    echo "1) small_1_0 - 250GB storage, 100GB transfer/month"
    echo "2) medium_1_0 - 500GB storage, 250GB transfer/month"
    echo "3) large_1_0 - 1TB storage, 500GB transfer/month"
    read -p "Enter choice (1-3) [default: 1]: " BUCKET_SIZE_CHOICE
    case ${BUCKET_SIZE_CHOICE:-1} in
        1) BUCKET_BUNDLE="small_1_0";;
        2) BUCKET_BUNDLE="medium_1_0";;
        3) BUCKET_BUNDLE="large_1_0";;
        *) BUCKET_BUNDLE="small_1_0";;
    esac
fi

echo -e "${GREEN}✓ Bucket configured${NC}"
echo ""

# OIDC Setup
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Step 4: AWS Authentication${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo ""

echo "Do you have an existing AWS IAM role for GitHub OIDC?"
read -p "(y/n) [default: n]: " HAS_ROLE

if [[ "$HAS_ROLE" =~ ^[Yy]$ ]]; then
    SETUP_OIDC="false"
    read -p "Enter your AWS Role ARN: " AWS_ROLE_ARN
else
    SETUP_OIDC="true"
    ROLE_NAME="GitHubActionsRole-${INSTANCE_NAME}"
    echo -e "${YELLOW}⚠️  You'll need to run setup-github-oidc.sh after this script${NC}"
fi

echo ""
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Configuration Summary${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo ""
echo "Application: $APP_TYPE_NAME"
echo "Instance: $INSTANCE_NAME ($SIZE_NAME)"
echo "Region: $AWS_REGION"
echo "OS: $OS_NAME"
if [[ "$DB_TYPE" != "none" ]]; then
    echo "Database: $DB_TYPE ($([ "$DB_EXTERNAL" = "true" ] && echo "external RDS" || echo "internal"))"
    [[ "$DB_EXTERNAL" = "true" ]] && echo "  RDS Instance: $DB_RDS_NAME"
    [[ "$DB_EXTERNAL" = "true" ]] && echo "  Database Name: $DB_NAME"
fi
if [[ "$ENABLE_BUCKET" =~ ^[Yy]$ ]]; then
    echo "Bucket: $BUCKET_NAME ($BUCKET_ACCESS, $BUCKET_BUNDLE)"
fi
if [[ "$SETUP_OIDC" == "true" ]]; then
    echo "OIDC: Will create new IAM role ($ROLE_NAME)"
else
    echo "OIDC: Using existing role"
    echo "  Role ARN: $AWS_ROLE_ARN"
fi
echo ""

read -p "Proceed with integration? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Integration cancelled."
    exit 0
fi

echo ""
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Installing Deployment System${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo ""

# Create directories
echo "Creating directory structure..."
mkdir -p .github/workflows
mkdir -p workflows

# Download or copy workflow files
echo "Installing workflow files..."

# Check if we're in the lamp-stack-lightsail repo
if [ -f "workflows/lightsail_common.py" ]; then
    echo "  ✓ Using local workflow files"
    SOURCE_DIR="."
else
    echo "  Downloading workflow files from GitHub..."
    REPO_URL="https://raw.githubusercontent.com/naveenraj44125-creator/lamp-stack-lightsail/main"
    
    # Download workflow files with error handling
    echo "  Downloading main workflow file..."
    if ! curl -sL "$REPO_URL/.github/workflows/deploy-generic-reusable.yml" -o .github/workflows/deploy-generic-reusable.yml; then
        echo -e "${RED}❌ Failed to download workflow file${NC}"
        echo "Please check your internet connection and try again."
        exit 1
    fi
    
    # Download Python modules with error handling
    echo "  Downloading Python deployment modules..."
    local failed_downloads=()
    for file in config_loader.py dependency_manager.py deploy-pre-steps-generic.py deploy-post-steps-generic.py deploy-post-steps-universal.py deployment_monitor.py lightsail_common.py lightsail_rds.py lightsail_bucket.py view_command_log.py os_detector.py; do
        if ! curl -sL "$REPO_URL/workflows/$file" -o "workflows/$file"; then
            failed_downloads+=("$file")
        fi
    done
    
    if [[ ${#failed_downloads[@]} -gt 0 ]]; then
        echo -e "${RED}❌ Failed to download some files: ${failed_downloads[*]}${NC}"
        echo ""
        echo -e "${BLUE}Troubleshooting:${NC}"
        echo "1. Check internet connection"
        echo "2. Verify repository URL is accessible: $REPO_URL"
        echo "3. Try downloading manually or clone the repository"
        echo ""
        exit 1
    fi
    
    # Download OIDC setup script if needed
    if [[ "$SETUP_OIDC" == "true" ]]; then
        echo "  Downloading OIDC setup script..."
        curl -sL "$REPO_URL/setup-github-oidc.sh" -o setup-github-oidc.sh
        chmod +x setup-github-oidc.sh
    fi
    
    SOURCE_DIR="."
fi

# Create deployment config
echo "Creating deployment configuration..."
cat > "deployment-${APP_TYPE}.config.yml" << EOF
# Deployment Configuration for $APP_TYPE_NAME
# Generated by integrate-lightsail-actions.sh

# AWS Configuration
aws:
  region: $AWS_REGION

# Lightsail Instance Configuration
lightsail:
  instance_name: $INSTANCE_NAME
  static_ip: ""  # Will be assigned automatically
  
  # Instance will be auto-created if it doesn't exist
  auto_create: true
  blueprint_id: "$BLUEPRINT_ID"  # $OS_NAME
  bundle_id: "$BUNDLE_ID"  # $SIZE_NAME
EOF

# Add bucket configuration if enabled
if [[ "$ENABLE_BUCKET" =~ ^[Yy]$ ]]; then
    cat >> "deployment-${APP_TYPE}.config.yml" << EOF
  
  # Lightsail Bucket Configuration
  bucket:
    enabled: true
    name: "$BUCKET_NAME"
    access_level: "$BUCKET_ACCESS"
    bundle_id: "$BUCKET_BUNDLE"
EOF
fi

# Add application configuration based on type
cat >> "deployment-${APP_TYPE}.config.yml" << 'EOF'

# Application Configuration
application:
  name: my-app
  version: "1.0.0"
  type: web
  
  # Files to include in deployment package
  package_files:
EOF

# Add package files based on app type
case $APP_TYPE in
    lamp)
        cat >> "deployment-${APP_TYPE}.config.yml" << 'EOF'
    - "*.php"
    - "css/"
    - "js/"
    - "config/"
    - "assets/"
EOF
        ;;
    nginx)
        cat >> "deployment-${APP_TYPE}.config.yml" << 'EOF'
    - "*.html"
    - "css/"
    - "js/"
    - "assets/"
    - "images/"
EOF
        ;;
    nodejs)
        cat >> "deployment-${APP_TYPE}.config.yml" << 'EOF'
    - "package.json"
    - "package-lock.json"
    - "*.js"
    - "src/"
    - "public/"
EOF
        ;;
    python)
        cat >> "deployment-${APP_TYPE}.config.yml" << 'EOF'
    - "requirements.txt"
    - "*.py"
    - "app/"
    - "static/"
    - "templates/"
EOF
        ;;
    react)
        cat >> "deployment-${APP_TYPE}.config.yml" << 'EOF'
    - "build/"
    - "package.json"
EOF
        ;;
esac

# Add dependencies configuration
cat >> "deployment-${APP_TYPE}.config.yml" << EOF

  package_fallback: true
  
  environment_variables:
    APP_ENV: production
    APP_DEBUG: false

# Dependencies Configuration
dependencies:
EOF

# Add dependencies based on app type
case $APP_TYPE in
    lamp)
        cat >> "deployment-${APP_TYPE}.config.yml" << EOF
  apache:
    enabled: true
    version: "latest"
    config:
      document_root: "/var/www/html"
      enable_ssl: false
      enable_rewrite: true
  
  php:
    enabled: true
    version: "8.3"
    config:
      extensions:
        - "pgsql"
        - "curl"
        - "mbstring"
        - "xml"
        - "zip"
      enable_composer: true
  
  $DB_TYPE:
    enabled: $([ "$DB_TYPE" != "none" ] && echo "true" || echo "false")
    external: $DB_EXTERNAL
EOF
        if [[ "$DB_EXTERNAL" == "true" ]]; then
            cat >> "deployment-${APP_TYPE}.config.yml" << EOF
    rds:
      database_name: "$DB_RDS_NAME"
      region: "$AWS_REGION"
      master_database: "$DB_NAME"
EOF
        fi
        ;;
    
    nginx)
        cat >> "deployment-${APP_TYPE}.config.yml" << EOF
  nginx:
    enabled: true
    version: "latest"
    config:
      document_root: "/var/www/html"
      enable_ssl: false
EOF
        ;;
    
    nodejs)
        cat >> "deployment-${APP_TYPE}.config.yml" << EOF
  nodejs:
    enabled: true
    version: "18"
    config:
      npm_packages:
        - "pm2"
      package_manager: "npm"
  
  $DB_TYPE:
    enabled: $([ "$DB_TYPE" != "none" ] && echo "true" || echo "false")
    external: $DB_EXTERNAL
EOF
        if [[ "$DB_EXTERNAL" == "true" ]]; then
            cat >> "deployment-${APP_TYPE}.config.yml" << EOF
    rds:
      database_name: "$DB_RDS_NAME"
      region: "$AWS_REGION"
      master_database: "$DB_NAME"
EOF
        fi
        ;;
    
    python)
        cat >> "deployment-${APP_TYPE}.config.yml" << EOF
  python:
    enabled: true
    version: "3.9"
    config:
      pip_packages:
        - "flask"
        - "gunicorn"
      virtual_env: true
  
  $DB_TYPE:
    enabled: $([ "$DB_TYPE" != "none" ] && echo "true" || echo "false")
    external: $DB_EXTERNAL
EOF
        if [[ "$DB_EXTERNAL" == "true" ]]; then
            cat >> "deployment-${APP_TYPE}.config.yml" << EOF
    rds:
      database_name: "$DB_RDS_NAME"
      region: "$AWS_REGION"
      master_database: "$DB_NAME"
EOF
        fi
        ;;
    
    react)
        cat >> "deployment-${APP_TYPE}.config.yml" << EOF
  nginx:
    enabled: true
    version: "latest"
    config:
      document_root: "/var/www/html"
      enable_ssl: false
  
  nodejs:
    enabled: true
    version: "18"
    config:
      npm_packages: []
      package_manager: "npm"
EOF
        ;;
esac

# Add common dependencies
cat >> "deployment-${APP_TYPE}.config.yml" << 'EOF'
  
  git:
    enabled: true
    config:
      install_lfs: false
  
  firewall:
    enabled: true
    config:
      allowed_ports:
        - "22"
        - "80"
        - "443"
      deny_all_other: true

# Deployment Configuration
deployment:
  timeouts:
    ssh_connection: 120
    command_execution: 300
    health_check: 180
  
  retries:
    max_attempts: 3
    ssh_connection: 5

# GitHub Actions Configuration
github_actions:
  triggers:
    push_branches:
      - main
      - master
    workflow_dispatch: true
  
  jobs:
    test:
      enabled: true
    deployment:
      deploy_on_push: true
      deploy_on_pr: false

# Monitoring and Logging
monitoring:
  health_check:
    endpoint: "/"
    expected_content: ""
    max_attempts: 10
    wait_between_attempts: 10
    initial_wait: 30
EOF

echo "  ✓ Created deployment-${APP_TYPE}.config.yml"

# Create GitHub Actions workflow
echo "Creating GitHub Actions workflow..."
cat > .github/workflows/deploy-to-lightsail.yml << EOF
name: Deploy to AWS Lightsail

on:
  push:
    branches: [main, master]
  workflow_dispatch:

permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    uses: ./.github/workflows/deploy-generic-reusable.yml
    with:
      config_file: 'deployment-${APP_TYPE}.config.yml'
      aws_region: '$AWS_REGION'
    secrets:
      aws_role_arn: \${{ vars.AWS_ROLE_ARN || secrets.AWS_ROLE_ARN }}
EOF

echo "  ✓ Created .github/workflows/deploy-to-lightsail.yml"

# Create README
echo "Creating integration README..."
cat > LIGHTSAIL-DEPLOYMENT.md << EOF
# Lightsail Deployment Integration

This repository has been integrated with AWS Lightsail automated deployment.

## Configuration

- **Application Type**: $APP_TYPE_NAME
- **Instance Name**: $INSTANCE_NAME ($SIZE_NAME)
- **AWS Region**: $AWS_REGION
- **Operating System**: $OS_NAME
$([ "$DB_TYPE" != "none" ] && echo "- **Database**: $DB_TYPE ($([ "$DB_EXTERNAL" = "true" ] && echo "external RDS" || echo "internal"))")
$([ "$DB_EXTERNAL" = "true" ] && echo "- **RDS Instance**: $DB_RDS_NAME")
$([ "$ENABLE_BUCKET" =~ ^[Yy]$ ] && echo "- **Bucket**: $BUCKET_NAME ($BUCKET_ACCESS)")

## Setup Steps

### 1. Configure AWS Authentication

$(if [[ "$SETUP_OIDC" == "true" ]]; then
    echo "Run the OIDC setup script:"
    echo "\`\`\`bash"
    echo "./setup-github-oidc.sh"
    echo "\`\`\`"
    echo ""
    echo "This will create an IAM role: \`$ROLE_NAME\`"
else
    echo "Add your AWS Role ARN to GitHub:"
    echo "1. Go to your repository Settings → Secrets and variables → Actions"
    echo "2. Add a new variable: \`AWS_ROLE_ARN\`"
    echo "3. Value: \`$AWS_ROLE_ARN\`"
fi)

### 2. Configure Database (if applicable)

$(if [[ "$DB_EXTERNAL" == "true" ]]; then
    echo "Set up RDS database secrets in GitHub:"
    echo "1. Go to Settings → Secrets and variables → Actions"
    echo "2. Add these secrets:"
    echo "   - \`DB_USER\`: Database username"
    echo "   - \`DB_PASSWORD\`: Database password"
fi)

### 3. Deploy

Push to main branch or manually trigger the workflow:
\`\`\`bash
git add .
git commit -m "Add Lightsail deployment"
git push origin main
\`\`\`

Or use GitHub Actions UI: Actions → Deploy to AWS Lightsail → Run workflow

## Files Added

- \`.github/workflows/deploy-to-lightsail.yml\` - Main deployment workflow
- \`.github/workflows/deploy-generic-reusable.yml\` - Reusable workflow
- \`deployment-${APP_TYPE}.config.yml\` - Deployment configuration
- \`workflows/*.py\` - Deployment automation scripts

## Monitoring

Check deployment status:
- GitHub Actions tab in your repository
- Deployment logs show detailed progress
- Health checks verify successful deployment

## Customization

Edit \`deployment-${APP_TYPE}.config.yml\` to customize:
- Dependencies and versions
- Environment variables
- Deployment steps
- Health check endpoints

## Troubleshooting

If deployment fails:
1. Check GitHub Actions logs
2. Verify AWS credentials are configured
3. Ensure instance name is unique
4. Check deployment config syntax

For more help, see: https://github.com/naveenraj44125-creator/lamp-stack-lightsail
EOF

echo "  ✓ Created LIGHTSAIL-DEPLOYMENT.md"

echo ""
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Step 5: AWS OIDC Setup${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo ""

# Validate prerequisites before OIDC setup
validate_oidc_prerequisites() {
    echo -e "${BLUE}Validating prerequisites for OIDC setup...${NC}"
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        echo -e "${RED}❌ AWS CLI not found. Please install it first.${NC}"
        echo "Install: brew install awscli (macOS) or sudo apt install awscli (Ubuntu)"
        return 1
    fi
    
    # Check AWS authentication
    if ! aws sts get-caller-identity &> /dev/null; then
        echo -e "${RED}❌ AWS CLI not configured or credentials invalid.${NC}"
        return 1
    fi
    
    # Check GitHub CLI for automatic variable setting
    if command -v gh &> /dev/null && gh auth status &> /dev/null; then
        echo -e "${GREEN}✓ GitHub CLI available for automatic variable setup${NC}"
    else
        echo -e "${YELLOW}⚠ GitHub CLI not available - you'll need to set AWS_ROLE_ARN manually${NC}"
    fi
    
    echo -e "${GREEN}✓ Prerequisites validated for OIDC setup${NC}"
    return 0
}

if [[ "$SETUP_OIDC" == "true" ]]; then
    echo -e "${GREEN}Setting up OIDC and IAM role...${NC}"
    
    # Validate prerequisites first
    if ! validate_oidc_prerequisites; then
        echo -e "${RED}❌ Prerequisites validation failed.${NC}"
        SETUP_OIDC="false"
    else
        # Check if AWS CLI is configured with enhanced error handling
    if ! aws sts get-caller-identity &> /dev/null; then
        echo -e "${RED}❌ AWS CLI is not configured${NC}"
        echo ""
        echo -e "${BLUE}AWS CLI Configuration Required:${NC}"
        echo ""
        echo -e "${YELLOW}Option 1: Interactive Configuration${NC}"
        echo "  aws configure"
        echo "  # You'll be prompted for:"
        echo "  # - AWS Access Key ID"
        echo "  # - AWS Secret Access Key"
        echo "  # - Default region (e.g., us-east-1)"
        echo "  # - Default output format (json)"
        echo ""
        echo -e "${YELLOW}Option 2: Use Credentials Script${NC}"
        echo "  source .aws-creds.sh"
        echo "  # If you have a credentials script in your repository"
        echo ""
        echo -e "${YELLOW}Option 3: Environment Variables${NC}"
        echo "  export AWS_ACCESS_KEY_ID=your_access_key"
        echo "  export AWS_SECRET_ACCESS_KEY=your_secret_key"
        echo "  export AWS_DEFAULT_REGION=us-east-1"
        echo ""
        echo -e "${YELLOW}Option 4: AWS SSO (if your organization uses it)${NC}"
        echo "  aws configure sso"
        echo ""
        echo -e "${BLUE}Getting AWS Credentials:${NC}"
        echo "1. Log into AWS Console → IAM → Users → Your User"
        echo "2. Go to 'Security credentials' tab"
        echo "3. Click 'Create access key'"
        echo "4. Choose 'Command Line Interface (CLI)'"
        echo "5. Copy the Access Key ID and Secret Access Key"
        echo ""
        echo -e "${GREEN}After configuring AWS credentials:${NC}"
        echo "• Run this script again for automatic OIDC setup"
        echo "• Or manually set up OIDC later: ./setup-github-oidc.sh"
        echo ""
        
        read -p "Do you want to configure AWS CLI now? (y/n): " CONFIGURE_AWS
        if [[ "$CONFIGURE_AWS" =~ ^[Yy]$ ]]; then
            echo ""
            echo -e "${BLUE}Starting AWS CLI configuration...${NC}"
            aws configure
            echo ""
            
            # Test the configuration
            if aws sts get-caller-identity &> /dev/null; then
                echo -e "${GREEN}✅ AWS CLI configured successfully!${NC}"
                echo ""
            else
                echo -e "${RED}❌ AWS CLI configuration failed or incomplete${NC}"
                echo "Please check your credentials and try again."
                echo ""
                SETUP_OIDC="false"
            fi
        else
            SETUP_OIDC="false"
        fi
    else
        # Get AWS account ID
        AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
        
        # Get GitHub repository info
        GITHUB_OWNER=$(git config --get remote.origin.url | sed -n 's#.*/\([^/]*\)/\([^/]*\)\.git#\1#p')
        REPO_NAME=$(git config --get remote.origin.url | sed -n 's#.*/\([^/]*\)/\([^/]*\)\.git#\2#p')
        
        if [ -z "$GITHUB_OWNER" ] || [ -z "$REPO_NAME" ]; then
            echo -e "${YELLOW}⚠️  Could not detect GitHub repository info${NC}"
            read -p "Enter GitHub owner/username: " GITHUB_OWNER
            read -p "Enter repository name: " REPO_NAME
        fi
        
        GITHUB_REPO="${GITHUB_OWNER}/${REPO_NAME}"
        
        # Set trust condition (default to main branch only)
        TRUST_CONDITION="repo:${GITHUB_REPO}:ref:refs/heads/main"
        
        echo "Repository: $GITHUB_REPO"
        echo "AWS Account: $AWS_ACCOUNT_ID"
        echo "IAM Role: $ROLE_NAME"
        echo ""
        
        # Create OIDC Provider (if it doesn't exist)
        OIDC_PROVIDER_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
        
        if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" &> /dev/null; then
            echo "✓ OIDC provider already exists"
        else
            echo "Creating OIDC provider..."
            aws iam create-open-id-connect-provider \
                --url https://token.actions.githubusercontent.com \
                --client-id-list sts.amazonaws.com \
                --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 \
                --tags Key=ManagedBy,Value=integrate-lightsail-actions > /dev/null
            echo "✓ OIDC provider created"
        fi
        
        # Create trust policy
        TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "$OIDC_PROVIDER_ARN"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "$TRUST_CONDITION"
        }
      }
    }
  ]
}
EOF
)
        
        echo "$TRUST_POLICY" > /tmp/trust-policy-${REPO_NAME}.json
        
        # Create or update IAM role
        if aws iam get-role --role-name "$ROLE_NAME" &> /dev/null; then
            echo "✓ Role exists, updating trust policy..."
            aws iam update-assume-role-policy \
                --role-name "$ROLE_NAME" \
                --policy-document file:///tmp/trust-policy-${REPO_NAME}.json > /dev/null
        else
            echo "Creating IAM role..."
            aws iam create-role \
                --role-name "$ROLE_NAME" \
                --assume-role-policy-document file:///tmp/trust-policy-${REPO_NAME}.json \
                --description "Role for GitHub Actions OIDC - ${REPO_NAME}" \
                --tags Key=ManagedBy,Value=integrate-lightsail-actions Key=Repository,Value=${REPO_NAME} > /dev/null
            echo "✓ IAM role created"
            
            # Attach policies
            echo "Attaching IAM policies..."
            aws iam attach-role-policy \
                --role-name "$ROLE_NAME" \
                --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess > /dev/null
            
            # Create Lightsail policy
            LIGHTSAIL_POLICY_NAME="${ROLE_NAME}-LightsailAccess"
            POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${LIGHTSAIL_POLICY_NAME}"
            
            if ! aws iam get-policy --policy-arn "$POLICY_ARN" &> /dev/null; then
                LIGHTSAIL_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"lightsail:*","Resource":"*"}]}'
                aws iam create-policy \
                    --policy-name "$LIGHTSAIL_POLICY_NAME" \
                    --policy-document "$LIGHTSAIL_POLICY" \
                    --description "Full access to AWS Lightsail" \
                    --tags Key=ManagedBy,Value=integrate-lightsail-actions > /dev/null
            fi
            
            aws iam attach-role-policy \
                --role-name "$ROLE_NAME" \
                --policy-arn "$POLICY_ARN" > /dev/null
            echo "✓ Lightsail policy attached"
        fi
        
        AWS_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"
        
        # Cleanup
        rm /tmp/trust-policy-${REPO_NAME}.json
        
        echo "✓ OIDC setup complete"
        echo ""
    fi
fi

# Set GitHub variable if gh CLI is available
if command -v gh &> /dev/null && [[ -n "$AWS_ROLE_ARN" ]]; then
    echo -e "${GREEN}Setting GitHub variable...${NC}"
    if gh variable set AWS_ROLE_ARN --body "$AWS_ROLE_ARN" 2>/dev/null; then
        echo "✓ AWS_ROLE_ARN variable set in GitHub"
    else
        echo -e "${YELLOW}⚠️  Could not set GitHub variable automatically${NC}"
        echo "Please set it manually:"
        echo "  1. Go to repository Settings → Secrets and variables → Actions"
        echo "  2. Add variable: AWS_ROLE_ARN"
        echo "  3. Value: $AWS_ROLE_ARN"
    fi
else
    if [[ -n "$AWS_ROLE_ARN" ]]; then
        echo -e "${YELLOW}⚠️  GitHub CLI not available${NC}"
        echo "Please set AWS_ROLE_ARN variable manually:"
        echo "  1. Go to repository Settings → Secrets and variables → Actions"
        echo "  2. Add variable: AWS_ROLE_ARN"
        echo "  3. Value: $AWS_ROLE_ARN"
    fi
fi

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅ Integration Complete!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo ""

echo "Files created:"
echo "  ✓ .github/workflows/deploy-to-lightsail.yml"
echo "  ✓ .github/workflows/deploy-generic-reusable.yml"
echo "  ✓ deployment-${APP_TYPE}.config.yml"
echo "  ✓ workflows/*.py (deployment modules)"
echo "  ✓ LIGHTSAIL-DEPLOYMENT.md"
echo ""

if [[ "$SETUP_OIDC" == "true" ]] && [[ -n "$AWS_ROLE_ARN" ]]; then
    echo -e "${GREEN}AWS Authentication:${NC}"
    echo "  ✓ OIDC provider configured"
    echo "  ✓ IAM role created: $ROLE_NAME"
    echo "  ✓ Role ARN: $AWS_ROLE_ARN"
    echo "  ✓ Trust condition: $TRUST_CONDITION"
    echo ""
fi

echo -e "${YELLOW}Next Steps:${NC}"
echo ""

echo "1. Review and customize deployment-${APP_TYPE}.config.yml"
echo ""

echo "2. Commit and push changes:"
echo "   ${BLUE}git add .${NC}"
echo "   ${BLUE}git commit -m \"Add Lightsail deployment automation\"${NC}"
echo "   ${BLUE}git push origin $CURRENT_BRANCH${NC}"
echo ""

echo "3. Monitor deployment in GitHub Actions tab"
echo ""

if [[ "$SETUP_OIDC" == "true" ]] && [[ -n "$AWS_ROLE_ARN" ]]; then
    echo -e "${GREEN}✓ OIDC is configured and ready to use!${NC}"
    echo ""
fi

echo -e "${GREEN}Your repository is now ready for automated Lightsail deployment! 🚀${NC}"
