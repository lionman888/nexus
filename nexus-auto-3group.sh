#!/bin/bash
set -e

BASE_CONTAINER_NAME="nexus-node"
IMAGE_NAME="nexus-node:latest"
LOG_DIR="/root/nexus_logs"

# 检查并安装所有依赖
function check_and_install_dependencies() {
    echo "=========================================="
    echo "正在检查和安装所需依赖..."
    echo "=========================================="

    # 检查是否为root用户
    if [ "$EUID" -ne 0 ]; then
        echo "错误：此脚本需要root权限运行"
        echo "请使用 sudo 运行此脚本"
        exit 1
    fi

    # 检查操作系统
    if [ ! -f /etc/os-release ]; then
        echo "错误：无法识别操作系统"
        exit 1
    fi

    source /etc/os-release
    OS=$ID
    VER=$VERSION_ID

    echo "检测到操作系统: $OS $VER"

    # 等待并处理包管理器锁定问题
    wait_for_package_manager

    # 更新包管理器
    echo "正在更新包管理器..."
    local max_retries=3
    local retry_count=0
    
    while [ $retry_count -lt $max_retries ]; do
        echo "尝试更新包管理器 (第 $((retry_count + 1))/$max_retries 次)..."
        
        # 确保包管理器可用
        wait_for_package_manager
        
        local update_success=false
        
        case $OS in
            ubuntu|debian)
                if apt update -y; then
                    update_success=true
                fi
                ;;
            centos|rhel|fedora)
                if command -v yum >/dev/null 2>&1; then
                    if yum update -y; then
                        update_success=true
                    fi
                elif command -v dnf >/dev/null 2>&1; then
                    if dnf update -y; then
                        update_success=true
                    fi
                fi
                ;;
            *)
                echo "警告：未知的操作系统，跳过包管理器更新"
                update_success=true
                ;;
        esac
        
        if [ "$update_success" = true ]; then
            echo "包管理器更新成功"
            break
        fi
        
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $max_retries ]; then
            echo "包管理器更新失败，等待10秒后重试..."
            sleep 10
        fi
    done
    
    if [ "$update_success" = false ]; then
        echo "警告：包管理器更新失败，但脚本将继续运行"
        echo "可能影响后续安装过程，建议检查网络连接"
    fi

    # 安装基础工具
    echo "正在安装基础工具..."
    local max_retries=3
    local retry_count=0
    
    while [ $retry_count -lt $max_retries ]; do
        echo "尝试安装基础工具 (第 $((retry_count + 1))/$max_retries 次)..."
        
        # 确保包管理器可用
        wait_for_package_manager
        
        local install_success=false
        
        case $OS in
            ubuntu|debian)
                if apt install -y curl wget git unzip software-properties-common apt-transport-https ca-certificates gnupg lsb-release; then
                    install_success=true
                fi
                ;;
            centos|rhel)
                if command -v yum >/dev/null 2>&1; then
                    if yum install -y curl wget git unzip; then
                        install_success=true
                    fi
                elif command -v dnf >/dev/null 2>&1; then
                    if dnf install -y curl wget git unzip; then
                        install_success=true
                    fi
                fi
                ;;
            fedora)
                if dnf install -y curl wget git unzip; then
                    install_success=true
                fi
                ;;
            *)
                echo "警告：未知操作系统，跳过基础工具安装"
                install_success=true
                ;;
        esac
        
        if [ "$install_success" = true ]; then
            echo "基础工具安装成功"
            break
        fi
        
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $max_retries ]; then
            echo "基础工具安装失败，等待10秒后重试..."
            sleep 10
        fi
    done
    
    if [ "$install_success" = false ]; then
        echo "警告：基础工具安装失败，但脚本将继续运行"
        echo "可能影响后续安装过程，建议检查网络连接"
    fi

    # 检查并安装 Docker
    check_docker

    # 检查并安装 Node.js/npm
    check_nodejs

    # 检查并安装 pm2
    check_pm2

    echo "=========================================="
    echo "所有依赖检查完成！"
    echo "=========================================="
}

# 等待包管理器锁定解除
function wait_for_package_manager() {
    echo "检查包管理器状态..."
    
    # 检查是否有锁定文件存在
    local lock_files=(
        "/var/lib/dpkg/lock"
        "/var/lib/dpkg/lock-frontend" 
        "/var/cache/apt/archives/lock"
        "/var/lib/apt/lists/lock"
    )
    
    local max_wait=300  # 最多等待5分钟
    local wait_time=0
    local check_interval=10
    
    while [ $wait_time -lt $max_wait ]; do
        local locks_found=false
        
        # 检查锁定文件
        for lock_file in "${lock_files[@]}"; do
            if [ -f "$lock_file" ]; then
                if fuser "$lock_file" >/dev/null 2>&1; then
                    locks_found=true
                    break
                fi
            fi
        done
        
        # 检查正在运行的包管理进程
        if pgrep -x "apt" >/dev/null 2>&1 || \
           pgrep -x "apt-get" >/dev/null 2>&1 || \
           pgrep -x "dpkg" >/dev/null 2>&1 || \
           pgrep -f "unattended-upgrade" >/dev/null 2>&1; then
            locks_found=true
        fi
        
        if [ "$locks_found" = false ]; then
            echo "包管理器可用"
            return 0
        fi
        
        if [ $wait_time -eq 0 ]; then
            echo "检测到包管理器正在使用中..."
            echo "常见原因：系统自动更新、其他apt进程正在运行"
        fi
        
        echo "等待包管理器释放... ($((wait_time + check_interval))/${max_wait}秒)"
        sleep $check_interval
        wait_time=$((wait_time + check_interval))
    done
    
    # 如果等待超时，提供解决方案
    echo "=========================================="
    echo "警告：包管理器锁定等待超时！"
    echo "=========================================="
    echo "检测到以下可能的解决方案："
    echo ""
    
    # 显示正在运行的相关进程
    echo "正在运行的包管理进程："
    ps aux | grep -E "(apt|dpkg|unattended-upgrade)" | grep -v grep || echo "未发现相关进程"
    echo ""
    
    echo "请选择解决方案："
    echo "1. 继续等待（推荐）"
    echo "2. 尝试终止自动更新进程"
    echo "3. 强制解除锁定（危险）"
    echo "4. 退出脚本，手动处理"
    echo ""
    
    read -rp "请输入选项 (1-4): " choice
    
    case $choice in
        1)
            echo "继续等待包管理器释放..."
            wait_for_package_manager  # 递归调用，继续等待
            ;;
        2)
            echo "尝试终止自动更新进程..."
            pkill -f unattended-upgrade 2>/dev/null || true
            systemctl stop unattended-upgrades 2>/dev/null || true
            sleep 10
            wait_for_package_manager  # 重新检查
            ;;
        3)
            echo "警告：正在强制删除锁定文件..."
            echo "这可能会导致系统不稳定！"
            read -rp "确认执行？(输入 YES 确认): " confirm
            if [ "$confirm" = "YES" ]; then
                for lock_file in "${lock_files[@]}"; do
                    if [ -f "$lock_file" ]; then
                        rm -f "$lock_file"
                        echo "删除锁定文件: $lock_file"
                    fi
                done
                # 重新配置dpkg
                dpkg --configure -a
                echo "已尝试强制解除锁定"
            else
                echo "已取消强制解锁"
                exit 1
            fi
            ;;
        4)
            echo "退出脚本。请手动处理包管理器锁定问题后重新运行。"
            echo ""
            echo "手动处理建议："
            echo "1. 等待系统自动更新完成"
            echo "2. 重启系统"
            echo "3. 或执行以下命令："
            echo "   sudo systemctl stop unattended-upgrades"
            echo "   sudo pkill -f unattended-upgrade"
            exit 1
            ;;
        *)
            echo "无效选项，退出脚本"
            exit 1
            ;;
    esac
}

# 检查并安装 Node.js/npm
function check_nodejs() {
    echo "检查 Node.js/npm..."
    
    if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
        echo "正在安装 Node.js 和 npm..."
        
        local max_retries=3
        local retry_count=0
        
        while [ $retry_count -lt $max_retries ]; do
            echo "尝试安装 Node.js/npm (第 $((retry_count + 1))/$max_retries 次)..."
            
            # 确保包管理器可用
            wait_for_package_manager
            
            case $OS in
                ubuntu|debian)
                    # 使用 NodeSource 官方仓库安装最新 LTS 版本
                    if curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && apt install -y nodejs; then
                        break
                    fi
                    ;;
                centos|rhel|fedora)
                    # 使用 NodeSource 官方仓库
                    if curl -fsSL https://rpm.nodesource.com/setup_lts.x | bash -; then
                        if command -v yum >/dev/null 2>&1; then
                            if yum install -y nodejs npm; then
                                break
                            fi
                        elif command -v dnf >/dev/null 2>&1; then
                            if dnf install -y nodejs npm; then
                                break
                            fi
                        fi
                    fi
                    ;;
                *)
                    echo "请手动安装 Node.js 和 npm"
                    exit 1
                    ;;
            esac
            
            retry_count=$((retry_count + 1))
            if [ $retry_count -lt $max_retries ]; then
                echo "安装失败，等待10秒后重试..."
                sleep 10
            fi
        done
        
        # 验证安装
        if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
            echo "Node.js $(node --version) 和 npm $(npm --version) 安装成功"
        else
            echo "错误：Node.js/npm 安装失败"
            echo "请尝试以下解决方案："
            echo "1. 检查网络连接"
            echo "2. 等待几分钟后重新运行脚本"
            echo "3. 手动安装 Node.js: https://nodejs.org/"
            exit 1
        fi
    else
        echo "Node.js $(node --version) 和 npm $(npm --version) 已安装"
    fi
}

# 检查并安装 pm2
function check_pm2() {
    echo "检查 pm2..."
    
    if ! command -v pm2 >/dev/null 2>&1; then
        echo "正在安装 pm2..."
        
        # 配置npm使用淘宝镜像源
        echo "配置npm使用淘宝镜像源..."
        npm config set registry https://registry.npmmirror.com/
        
        # 验证镜像源配置
        echo "当前npm镜像源: $(npm config get registry)"
        
        # 安装pm2
        npm install pm2@latest -g
        
        # 验证安装
        if command -v pm2 >/dev/null 2>&1; then
            echo "pm2 $(pm2 --version) 安装成功"
        else
            echo "错误：pm2 安装失败"
            exit 1
        fi
    else
        echo "pm2 $(pm2 --version) 已安装"
    fi
}

# 检查 Docker 是否安装
function check_docker() {
    echo "检查 Docker..."
    
    if ! command -v docker >/dev/null 2>&1; then
        echo "正在安装 Docker..."
        
        local max_retries=3
        local retry_count=0
        
        while [ $retry_count -lt $max_retries ]; do
            echo "尝试安装 Docker (第 $((retry_count + 1))/$max_retries 次)..."
            
            # 确保包管理器可用
            wait_for_package_manager
            
            local install_success=false
            
            case $OS in
                ubuntu|debian)
                    # 卸载旧版本
                    apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
                    
                    # 安装 Docker 官方 GPG 密钥
                    if curl -fsSL https://download.docker.com/linux/$OS/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg; then
                        # 添加 Docker 官方 APT 仓库
                        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/$OS $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
                        
                        # 更新包索引并安装
                        if apt update -y && apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin; then
                            install_success=true
                        fi
                    fi
                    ;;
                centos|rhel)
                    # 卸载旧版本
                    if command -v yum >/dev/null 2>&1; then
                        yum remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine 2>/dev/null || true
                        if yum install -y yum-utils && yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo && yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin; then
                            install_success=true
                        fi
                    elif command -v dnf >/dev/null 2>&1; then
                        dnf remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine 2>/dev/null || true
                        if dnf install -y dnf-plugins-core && dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo && dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin; then
                            install_success=true
                        fi
                    fi
                    ;;
                fedora)
                    dnf remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-selinux docker-engine-selinux docker-engine 2>/dev/null || true
                    if dnf install -y dnf-plugins-core && dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo && dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin; then
                        install_success=true
                    fi
                    ;;
            esac
            
            if [ "$install_success" = true ]; then
                break
            fi
            
            retry_count=$((retry_count + 1))
            if [ $retry_count -lt $max_retries ]; then
                echo "Docker安装失败，等待10秒后重试..."
                sleep 10
            fi
        done
        
        if [ "$install_success" = false ]; then
            echo "错误：Docker 安装失败"
            echo "请尝试以下解决方案："
            echo "1. 检查网络连接"
            echo "2. 等待几分钟后重新运行脚本"
            echo "3. 手动安装 Docker: https://docs.docker.com/engine/install/"
            exit 1
        fi
        
        # 启动并启用 Docker 服务
        systemctl enable docker
        systemctl start docker
        
        # 验证安装
        if command -v docker >/dev/null 2>&1; then
            echo "Docker $(docker --version) 安装成功"
        else
            echo "错误：Docker 安装失败"
            exit 1
        fi
    else
        echo "Docker $(docker --version) 已安装"
        
        # 确保 Docker 服务正在运行
        if ! systemctl is-active --quiet docker; then
            echo "启动 Docker 服务..."
            systemctl start docker
        fi
    fi
}

# 构建docker镜像函数
function build_image() {
    WORKDIR=$(mktemp -d)
    cd "$WORKDIR"

    cat > Dockerfile <<EOF
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PROVER_ID_FILE=/root/.nexus/node-id

RUN apt-get update && apt-get install -y \\
    curl \\
    screen \\
    bash \\
    && rm -rf /var/lib/apt/lists/*

RUN curl -sSL https://cli.nexus.xyz/ | sh

RUN ln -sf /root/.nexus/bin/nexus-network /usr/local/bin/nexus-network

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
EOF

    cat > entrypoint.sh <<EOF
#!/bin/bash
set -e

PROVER_ID_FILE="/root/.nexus/node-id"

if [ -z "\$NODE_ID" ]; then
    echo "错误：未设置 NODE_ID 环境变量"
    exit 1
fi

echo "\$NODE_ID" > "\$PROVER_ID_FILE"
echo "使用的 node-id: \$NODE_ID"

if ! command -v nexus-network >/dev/null 2>&1; then
    echo "错误：nexus-network 未安装或不可用"
    exit 1
fi

screen -S nexus -X quit >/dev/null 2>&1 || true

echo "启动 nexus-network 节点..."
screen -dmS nexus bash -c "nexus-network start --node-id \$NODE_ID &>> /root/nexus.log"

sleep 3

if screen -list | grep -q "nexus"; then
    echo "节点已在后台启动。"
    echo "日志文件：/root/nexus.log"
    echo "可以使用 docker logs \$CONTAINER_NAME 查看日志"
else
    echo "节点启动失败，请检查日志。"
    cat /root/nexus.log
    exit 1
fi

tail -f /root/nexus.log
EOF

    docker build -t "$IMAGE_NAME" .

    cd -
    rm -rf "$WORKDIR"
}

# 显示所有运行中的节点
function list_nodes() {
    echo "当前节点状态："
    echo "--------------------------------------------------------------------------------------------------------"
    printf "%-6s %-20s %-10s %-10s %-10s %-20s\n" "序号" "节点ID" "CPU使用率" "内存使用" "内存限制" "状态"
    echo "--------------------------------------------------------------------------------------------------------"
    
    local all_nodes=($(get_all_nodes))
    for i in "${!all_nodes[@]}"; do
        local node_id=${all_nodes[$i]}
        local container_name="${BASE_CONTAINER_NAME}-${node_id}"
        local container_info=$(docker stats --no-stream --format "{{.CPUPerc}},{{.MemUsage}},{{.MemPerc}}" $container_name 2>/dev/null)
        
        if [ -n "$container_info" ]; then
            # 解析容器信息
            IFS=',' read -r cpu_usage mem_usage mem_limit mem_perc <<< "$container_info"
            local status=$(docker ps -a --filter "name=$container_name" --format "{{.Status}}")
            
            # 格式化内存显示
            mem_usage=$(echo $mem_usage | sed 's/\([0-9.]*\)\([A-Za-z]*\)/\1 \2/')
            mem_limit=$(echo $mem_limit | sed 's/\([0-9.]*\)\([A-Za-z]*\)/\1 \2/')
            
            # 显示节点信息
            printf "%-6d %-20s %-10s %-10s %-10s %-20s\n" \
                $((i+1)) \
                "$node_id" \
                "$cpu_usage" \
                "$mem_usage" \
                "$mem_limit" \
                "$(echo $status | cut -d' ' -f1)"
        else
            # 如果容器不存在或未运行
            local status=$(docker ps -a --filter "name=$container_name" --format "{{.Status}}")
            if [ -n "$status" ]; then
                printf "%-6d %-20s %-10s %-10s %-10s %-20s\n" \
                    $((i+1)) \
                    "$node_id" \
                    "N/A" \
                    "N/A" \
                    "N/A" \
                    "$(echo $status | cut -d' ' -f1)"
            fi
        fi
    done
    echo "--------------------------------------------------------------------------------------------------------"
    echo "提示："
    echo "- CPU使用率：显示容器CPU使用百分比"
    echo "- 内存使用：显示容器当前使用的内存"
    echo "- 内存限制：显示容器内存使用限制"
    echo "- 状态：显示容器的运行状态"
    read -p "按任意键返回菜单"
}

# 获取所有运行中的节点ID
function get_running_nodes() {
    docker ps --filter "name=${BASE_CONTAINER_NAME}" --filter "status=running" --format "{{.Names}}" | sed "s/${BASE_CONTAINER_NAME}-//"
}

# 获取所有节点ID（包括已停止的）
function get_all_nodes() {
    docker ps -a --filter "name=${BASE_CONTAINER_NAME}" --format "{{.Names}}" | sed "s/${BASE_CONTAINER_NAME}-//"
}

# 删除全部节点
function uninstall_all_nodes() {
    local all_nodes=($(get_all_nodes))
    
    if [ ${#all_nodes[@]} -eq 0 ]; then
        echo "当前没有节点"
        read -p "按任意键返回菜单"
        return
    fi

    echo "警告：此操作将删除所有节点！"
    echo "当前共有 ${#all_nodes[@]} 个节点："
    for node_id in "${all_nodes[@]}"; do
        echo "- $node_id"
    done
    
    read -rp "确定要删除所有节点吗？(y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消操作"
        read -p "按任意键返回菜单"
        return
    fi

    echo "开始删除所有节点..."
    for node_id in "${all_nodes[@]}"; do
        echo "正在卸载节点 $node_id ..."
        docker rm -f "${BASE_CONTAINER_NAME}-${node_id}" 2>/dev/null || true
    done

    # 删除所有轮换容器
    for i in {1..7}; do
        docker rm -f "${BASE_CONTAINER_NAME}-group-$i" 2>/dev/null || true
    done

    # 停止并删除轮换进程
    for i in {1..7}; do
        pm2 delete "nexus-group-$i" 2>/dev/null || true
    done

    echo "所有节点已删除完成！"
    read -p "按任意键返回菜单"
}

# 读取ID文件并分组启动
function start_auto_rotation() {
    # 检查id.txt文件是否存在
    if [ ! -f "id.txt" ]; then
        echo "错误：找不到 id.txt 文件"
        echo "请在当前目录创建 id.txt 文件，每行一个 node-id"
        read -p "按任意键返回菜单"
        return
    fi

    # 读取所有ID
    echo "正在读取 id.txt 文件..."
    node_ids=()
    while IFS= read -r line; do
        # 去除空白字符
        line=$(echo "$line" | tr -d '\r\n' | xargs)
        if [ -n "$line" ]; then
            node_ids+=("$line")
        fi
    done < id.txt

    if [ ${#node_ids[@]} -eq 0 ]; then
        echo "错误：id.txt 文件为空或无有效ID"
        read -p "按任意键返回菜单"
        return
    fi

    echo "读取到 ${#node_ids[@]} 个ID"

    # 按3个ID一组分配，最多7个容器
    max_containers=7
    ids_per_container=3
    max_ids=$((max_containers * ids_per_container))

    # 计算实际使用的ID数量
    used_ids=${#node_ids[@]}
    if [ $used_ids -gt $max_ids ]; then
        used_ids=$max_ids
        echo "注意：只使用前 $max_ids 个ID，剩余 $((${#node_ids[@]} - max_ids)) 个ID将被闲置"
    fi

    # 计算需要的容器数量
    container_count=$(((used_ids + ids_per_container - 1) / ids_per_container))
    echo "将启动 $container_count 个容器，每个容器轮换 $ids_per_container 个ID"

    # 停止旧的轮换进程
    echo "停止旧的轮换进程..."
    for i in {1..7}; do
        pm2 delete "nexus-group-$i" 2>/dev/null || true
    done

    echo "开始构建镜像..."
    build_image

    # 创建启动脚本目录
    script_dir="/root/nexus_scripts"
    mkdir -p "$script_dir"

    # 为每个容器组创建轮换脚本
    for ((i=1; i<=container_count; i++)); do
        start_idx=$(((i-1) * ids_per_container))
        end_idx=$((start_idx + ids_per_container - 1))
        
        # 获取当前组的ID
        group_ids=()
        for ((j=start_idx; j<=end_idx && j<used_ids; j++)); do
            group_ids+=("${node_ids[$j]}")
        done

        echo "容器组 $i 使用ID: ${group_ids[*]}"

        # 创建该组的轮换脚本
        cat > "$script_dir/rotate-group-$i.sh" <<EOF
#!/bin/bash
set -e

CONTAINER_NAME="${BASE_CONTAINER_NAME}-group-$i"
LOG_FILE="${LOG_DIR}/nexus-group-$i.log"

# 确保日志目录和文件存在
mkdir -p "${LOG_DIR}"
touch "\$LOG_FILE"
chmod 644 "\$LOG_FILE"

# 停止并删除现有容器
docker rm -f "\$CONTAINER_NAME" 2>/dev/null || true

# 启动容器（使用第一个node-id）
echo "容器组 $i 启动，使用node-id: ${group_ids[0]}"
docker run -d --name "\$CONTAINER_NAME" -v "\$LOG_FILE:/root/nexus.log" -e NODE_ID="${group_ids[0]}" "$IMAGE_NAME"

# 等待容器启动
sleep 30

while true; do
EOF

        # 添加轮换逻辑
        for group_id in "${group_ids[@]}"; do
            cat >> "$script_dir/rotate-group-$i.sh" <<EOF
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 容器组 $i 切换到node-id: $group_id"
    
    # 停止当前容器
    docker stop "\$CONTAINER_NAME" 2>/dev/null || true
    docker rm "\$CONTAINER_NAME" 2>/dev/null || true
    
    # 使用新的node-id启动容器
    docker run -d --name "\$CONTAINER_NAME" -v "\$LOG_FILE:/root/nexus.log" -e NODE_ID="$group_id" "$IMAGE_NAME"
    
    # 等待2小时
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 容器组 $i 等待2小时..."
    sleep 7200
EOF
        done

        cat >> "$script_dir/rotate-group-$i.sh" <<EOF
done
EOF

        # 设置脚本权限
        chmod +x "$script_dir/rotate-group-$i.sh"

        # 使用 pm2 启动轮换脚本
        pm2 start "$script_dir/rotate-group-$i.sh" --name "nexus-group-$i"
    done

    pm2 save

    echo "=========================================="
    echo "节点轮换已启动！"
    echo "总共使用 $used_ids 个ID，启动了 $container_count 个容器组"
    echo "每个容器组轮换 $ids_per_container 个ID，每2小时切换一次"
    if [ ${#node_ids[@]} -gt $max_ids ]; then
        echo "闲置ID数量: $((${#node_ids[@]} - max_ids))"
    fi
    echo "=========================================="
    echo "管理命令："
    echo "- 查看运行状态: pm2 status"
    echo "- 查看日志: pm2 logs"
    echo "- 停止所有轮换: pm2 stop all"
    read -p "按任意键返回菜单"
}

# 手动切换指定组到下一个ID
function switch_group_to_next_id() {
    # 检查id.txt文件是否存在
    if [ ! -f "id.txt" ]; then
        echo "错误：找不到 id.txt 文件"
        read -p "按任意键返回菜单"
        return
    fi

    # 读取所有ID
    node_ids=()
    while IFS= read -r line; do
        line=$(echo "$line" | tr -d '\r\n' | xargs)
        if [ -n "$line" ]; then
            node_ids+=("$line")
        fi
    done < id.txt

    if [ ${#node_ids[@]} -eq 0 ]; then
        echo "错误：id.txt 文件为空"
        read -p "按任意键返回菜单"
        return
    fi

    # 显示当前运行的组
    echo "当前运行的容器组："
    for i in {1..7}; do
        container_name="${BASE_CONTAINER_NAME}-group-$i"
        if docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
            current_id=$(docker exec $container_name cat /root/.nexus/node-id 2>/dev/null || echo "未知")
            echo "组 $i: $current_id"
        fi
    done

    echo ""
    read -rp "请输入要切换的组号 (1-7): " group_num

    # 验证输入
    if [[ ! "$group_num" =~ ^[1-7]$ ]]; then
        echo "无效的组号"
        read -p "按任意键返回菜单"
        return
    fi

    container_name="${BASE_CONTAINER_NAME}-group-$group_num"
    
    # 检查容器是否存在
    if ! docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
        echo "容器组 $group_num 未运行"
        read -p "按任意键返回菜单"
        return
    fi

    # 获取当前ID
    current_id=$(docker exec $container_name cat /root/.nexus/node-id 2>/dev/null)
    if [ -z "$current_id" ]; then
        echo "无法获取当前ID"
        read -p "按任意键返回菜单"
        return
    fi

    # 找到当前ID在数组中的位置
    current_index=-1
    for i in "${!node_ids[@]}"; do
        if [ "${node_ids[$i]}" = "$current_id" ]; then
            current_index=$i
            break
        fi
    done

    if [ $current_index -eq -1 ]; then
        echo "当前ID '$current_id' 不在id.txt文件中，使用第一个ID"
        next_id="${node_ids[0]}"
    else
        # 计算下一个ID的索引
        next_index=$(((current_index + 1) % ${#node_ids[@]}))
        next_id="${node_ids[$next_index]}"
    fi

    echo "当前ID: $current_id"
    echo "下一个ID: $next_id"
    read -rp "确认切换吗？(y/N): " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消切换"
        read -p "按任意键返回菜单"
        return
    fi

    # 执行切换
    echo "正在切换容器组 $group_num 到新ID: $next_id"
    
    # 停止并删除现有容器
    docker stop $container_name 2>/dev/null
    docker rm $container_name 2>/dev/null

    # 启动新容器
    log_file="${LOG_DIR}/nexus-group-$group_num.log"
    docker run -d --name $container_name \
        -v $log_file:/root/nexus.log \
        -e NODE_ID="$next_id" \
        "$IMAGE_NAME"

    if [ $? -eq 0 ]; then
        echo "切换成功！容器组 $group_num 现在使用ID: $next_id"
    else
        echo "切换失败！"
    fi
    
    read -p "按任意键返回菜单"
}

# 批量切换容器组到下一个ID
function batch_switch_to_next_id() {
    # 检查id.txt文件是否存在
    if [ ! -f "id.txt" ]; then
        echo "错误：找不到 id.txt 文件"
        read -p "按任意键返回菜单"
        return
    fi

    # 读取所有ID
    node_ids=()
    while IFS= read -r line; do
        line=$(echo "$line" | tr -d '\r\n' | xargs)
        if [ -n "$line" ]; then
            node_ids+=("$line")
        fi
    done < id.txt

    if [ ${#node_ids[@]} -eq 0 ]; then
        echo "错误：id.txt 文件为空"
        read -p "按任意键返回菜单"
        return
    fi

    # 显示当前运行的组
    echo "当前运行的容器组："
    running_groups=()
    for i in {1..7}; do
        container_name="${BASE_CONTAINER_NAME}-group-$i"
        if docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
            current_id=$(docker exec $container_name cat /root/.nexus/node-id 2>/dev/null || echo "未知")
            echo "组 $i: $current_id"
            running_groups+=($i)
        fi
    done

    if [ ${#running_groups[@]} -eq 0 ]; then
        echo "当前没有运行的容器组"
        read -p "按任意键返回菜单"
        return
    fi

    echo ""
    echo "批量切换选项："
    echo "1. 全部容器切换到下一个ID"
    echo "2. 指定容器组切换（支持多个组号和范围）"
    echo ""
    read -rp "请选择操作方式 (1-2): " mode

    target_groups=()
    
    case $mode in
        1)
            # 全部容器切换
            target_groups=("${running_groups[@]}")
            echo "将切换所有运行中的容器组: ${target_groups[*]}"
            ;;
        2)
            # 指定容器组切换
            echo ""
            echo "输入格式示例："
            echo "- 多个组号: 1 2 3 5"
            echo "- 范围: 2-5"
            echo "- 混合: 1 3-5 7"
            echo ""
            read -rp "请输入要切换的容器组: " input

            if [ -z "$input" ]; then
                echo "输入为空，已取消操作"
                read -p "按任意键返回菜单"
                return
            fi

            # 解析输入
            target_groups=($(parse_group_input "$input"))
            
            if [ ${#target_groups[@]} -eq 0 ]; then
                echo "无效的输入格式"
                read -p "按任意键返回菜单"
                return
            fi

            # 验证输入的组号是否在运行
            valid_groups=()
            for group in "${target_groups[@]}"; do
                if [[ " ${running_groups[*]} " =~ " $group " ]]; then
                    valid_groups+=($group)
                else
                    echo "警告：容器组 $group 未运行，将跳过"
                fi
            done

            if [ ${#valid_groups[@]} -eq 0 ]; then
                echo "没有有效的运行中容器组"
                read -p "按任意键返回菜单"
                return
            fi

            target_groups=("${valid_groups[@]}")
            echo "将切换以下容器组: ${target_groups[*]}"
            ;;
        *)
            echo "无效选项"
            read -p "按任意键返回菜单"
            return
            ;;
    esac

    echo ""
    read -rp "确认执行批量切换吗？(y/N): " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消操作"
        read -p "按任意键返回菜单"
        return
    fi

    # 执行批量切换
    echo "开始批量切换..."
    success_count=0
    fail_count=0

    for group_num in "${target_groups[@]}"; do
        echo ""
        echo "正在切换容器组 $group_num..."
        
        container_name="${BASE_CONTAINER_NAME}-group-$group_num"
        
        # 获取当前ID
        current_id=$(docker exec $container_name cat /root/.nexus/node-id 2>/dev/null)
        if [ -z "$current_id" ]; then
            echo "无法获取容器组 $group_num 的当前ID，跳过"
            ((fail_count++))
            continue
        fi

        # 找到当前ID在数组中的位置
        current_index=-1
        for i in "${!node_ids[@]}"; do
            if [ "${node_ids[$i]}" = "$current_id" ]; then
                current_index=$i
                break
            fi
        done

        if [ $current_index -eq -1 ]; then
            echo "当前ID '$current_id' 不在id.txt文件中，使用第一个ID"
            next_id="${node_ids[0]}"
        else
            # 计算下一个ID的索引
            next_index=$(((current_index + 1) % ${#node_ids[@]}))
            next_id="${node_ids[$next_index]}"
        fi

        echo "容器组 $group_num: $current_id -> $next_id"
        
        # 停止并删除现有容器
        docker stop $container_name 2>/dev/null
        docker rm $container_name 2>/dev/null

        # 启动新容器
        log_file="${LOG_DIR}/nexus-group-$group_num.log"
        docker run -d --name $container_name \
            -v $log_file:/root/nexus.log \
            -e NODE_ID="$next_id" \
            "$IMAGE_NAME"

        if [ $? -eq 0 ]; then
            echo "容器组 $group_num 切换成功！"
            ((success_count++))
        else
            echo "容器组 $group_num 切换失败！"
            ((fail_count++))
        fi
        
        # 添加短暂延迟，避免同时启动过多容器
        sleep 2
    done

    echo ""
    echo "=========================================="
    echo "批量切换完成！"
    echo "成功: $success_count 个容器组"
    echo "失败: $fail_count 个容器组"
    echo "=========================================="
    
    read -p "按任意键返回菜单"
}

# 解析用户输入的组号（支持单个、多个、范围）
function parse_group_input() {
    local input="$1"
    local groups=()
    
    # 将输入按空格分割
    IFS=' ' read -ra parts <<< "$input"
    
    for part in "${parts[@]}"; do
        # 检查是否是范围格式 (如 2-5)
        if [[ "$part" =~ ^([1-7])-([1-7])$ ]]; then
            local start=${BASH_REMATCH[1]}
            local end=${BASH_REMATCH[2]}
            
            # 确保范围有效
            if [ $start -le $end ]; then
                for ((i=start; i<=end; i++)); do
                    groups+=($i)
                done
            fi
        # 检查是否是单个数字
        elif [[ "$part" =~ ^[1-7]$ ]]; then
            groups+=($part)
        fi
    done
    
    # 去重并排序
    printf '%s\n' "${groups[@]}" | sort -nu | tr '\n' ' '
}

# 主菜单
while true; do
    clear
    echo "脚本由哈哈哈哈编写，推特 @ferdie_jhovie，免费开源，请勿相信收费"
    echo "如有问题，可联系推特，仅此只有一个号"
    echo "========== Nexus 多节点管理（3ID一组版） =========="
    echo "1. 检查和安装所有依赖（Docker、Node.js、npm、pm2）"
    echo "2. 自动轮换启动节点（从id.txt读取，3个ID一组，最多7容器）"
    echo "3. 显示所有节点状态"
    echo "4. 删除全部节点"
    echo "5. 手动切换指定组到下一个ID"
    echo "6. 批量切换容器组到下一个ID"
    echo "7. 退出"
    echo "=================================================="

    read -rp "请输入选项(1-7): " choice

    case $choice in
        1)
            check_and_install_dependencies
            read -p "按任意键返回菜单"
            ;;
        2)
            start_auto_rotation
            ;;
        3)
            list_nodes
            ;;
        4)
            uninstall_all_nodes
            ;;
        5)
            switch_group_to_next_id
            ;;
        6)
            batch_switch_to_next_id
            ;;
        7)
            echo "退出脚本。"
            exit 0
            ;;
        *)
            echo "无效选项，请重新输入。"
            read -p "按任意键继续"
            ;;
    esac
done 
