#!/bin/bash
# ==============================================================================
# Projeto Final - Sistemas Operacionais Abertos (IFRN - Campus Canguaretama)
# Ferramenta: netadmin.sh
# Descricao: Diagnostico e auditoria de servidores Linux
# ==============================================================================

# =============================================================================
# Nome: Valeria Sales Clemente Souza
# TSI 2026.2
# =============================================================================


# Variáveis globais de controle
MODO_DETALHADO=0
ARQUIVO_SAIDA=""
EXECUTAR_INFO=0
DESTINO_PING=""
ARQUIVO_PING=""
LISTAR_PORTAS=0
PORTAS_CHECK=""
ARQUIVO_LOG=""

# Função de limpeza (requisito 'trap')
limpar_temporarios() {
    rm -f /tmp/netadmin_*.tmp
}
trap limpar_temporarios EXIT

# Função de ajuda (-h)
mostrar_ajuda() {
    echo "Uso: $0 [OPCOES]"
    echo "  -i            Exibir informacoes do servidor e interfaces de rede."
    echo "  -p DESTINO    Testar conectividade com um destino."
    echo "  -P ARQUIVO    Testar conectividade com destinos de um arquivo."
    echo "  -s            Listar servicos e portas em escuta."
    echo "  -c PORTAS     Verificar portas especificas (ex: 22,80,443)."
    echo "  -l ARQUIVO    Analisar arquivo de log."
    echo "  -o ARQUIVO    Salvar saida em arquivo."
    echo "  -v            Ativar modo detalhado."
    echo "  -h            Exibir esta ajuda."
}

# ==========================================
# MÓDULO 1: INFORMAÇÕES DO SERVIDOR E REDE (-i)
# ==========================================
diagnostico_rede() {
    if ! command -v ip >/dev/null 2>&1; then
        echo "Erro: Comando 'ip' nao encontrado no sistema." >&2
        return 1
    fi

    local total_ifaces=0
    local ativas=0
    local desativadas=0
    local sem_ipv4=0
    local alertas=()

    if [ $MODO_DETALHADO -eq 1 ]; then
        echo "=== INFORMACOES DO SERVIDOR (MODO DETALHADO) ==="
        echo "INFORMACOES DO SISTEMA"
        echo "Hostname: $(hostname)"
        echo "Data/Hora: $(date '+%d/%m/%Y %H:%M:%S')"
        echo "Sistema operacional: $(uname -s)"
        echo "Kernel: $(uname -r)"
        echo "Tempo ligado: $(uptime -p 2>/dev/null || uptime)"
        echo ""
    else
        echo "=== DIAGNOSTICO DE REDE ==="
        echo "Servidor: $(hostname) | Data: $(date '+%d/%m/%Y %H:%M:%S')"
        echo ""
    fi

    echo "INTERFACES DE REDE"
    for caminho_iface in /sys/class/net/*; do
        local iface
        iface=$(basename "$caminho_iface")
        # Ignora loopback no modo normal para ficar mais limpo, ou inclui se quiser
        [ "$iface" == "lo" ] && [ $MODO_DETALHADO -eq 0 ] && continue

        ((total_ifaces++))

        local info_link estado mac mtu ipv4 ipv6
        info_link=$(LC_ALL=C ip -o link show "$iface")
        mac=$(echo "$info_link" | awk -F'link/ether ' '{print $2}' | awk '{print $1}')
        [ -z "$mac" ] && mac="N/A"
        mtu=$(echo "$info_link" | grep -oE 'mtu [0-9]+' | awk '{print $2}')

        if echo "$info_link" | grep -qE "state UP|<[^>]*UP[^>]*>"; then
            estado="ATIVA"
            ((ativas++))
        else
            estado="DESATIVADA"
            ((desativadas++))
            alertas+=("Interface $iface desativada.")
        fi

        ipv4=$(LC_ALL=C ip -4 -o addr show "$iface" | awk '{print $4}' | paste -sd ", " -)
        if [ -z "$ipv4" ]; then
            ipv4="NAO CONFIGURADO"
            ((sem_ipv4++))
            if [ "$estado" == "ATIVA" ]; then
                alertas+=("Interface $iface ativa, mas sem endereco IPv4 configurado.")
            else
                alertas+=("Interface $iface sem endereco IPv4.")
            fi
        fi

        ipv6=$(LC_ALL=C ip -6 -o addr show "$iface" | awk '{print $4}' | paste -sd ", " -)
        [ -z "$ipv6" ] && ipv6="NAO CONFIGURADO"

        echo "$iface"
        echo "  Estado: $estado"
        if [ $MODO_DETALHADO -eq 1 ]; then
            echo "  Endereco MAC: $mac"
            echo "  IPv4: $ipv4"
            echo "  IPv6: $ipv6"
            echo "  MTU: ${mtu:-N/A}"
        else
            echo "  Endereco IPv4: $ipv4"
        fi

        if [ "$estado" == "DESATIVADA" ]; then
            echo "  ATENCAO: Interface desativada."
        elif [ "$ipv4" == "NAO CONFIGURADO" ]; then
            echo "  ATENCAO: Interface ativa, mas sem endereco IP configurado."
        fi
    done

    echo ""
    echo "ROTAS DE REDE"
    local rota_padrao
    rota_padrao=$(LC_ALL=C ip route show default | head -n 1)

    if [ $MODO_DETALHADO -eq 1 ]; then
        LC_ALL=C ip route show
    fi

    if [ -n "$rota_padrao" ]; then
        echo "Rota padrao: $rota_padrao"
    else
        echo "Rota padrao: NAO CONFIGURADA"
        echo "ATENCAO: O servidor pode nao conseguir acessar redes externas."
        alertas+=("Rota padrao nao configurada.")
    fi

    echo ""
    if [ $MODO_DETALHADO -eq 1 ]; then
        echo "COMANDOS UTILIZADOS"
        echo "hostname, date, uname -r, uptime, ip link, ip address, ip route"
        echo ""
        echo "DIAGNOSTICO"
        if [ ${#alertas[@]} -eq 0 ]; then
            echo "Nenhuma situacao critica identificada."
        else
            local idx=1
            for item in "${alertas[@]}"; do
                echo "$idx. $item"
                ((idx++))
            done
        fi
    else
        echo "=== RESUMO DO DIAGNOSTICO ==="
        echo "Interfaces encontradas: $total_ifaces"
        echo "Interfaces ativas: $ativas"
        echo "Interfaces desativadas: $desativadas"
        echo "Interfaces sem endereco IPv4: $sem_ipv4"
        if [ -n "$rota_padrao" ]; then
            echo "Rota padrao: CONFIGURADA"
        else
            echo "Rota padrao: NAO CONFIGURADA"
        fi
        echo "Foram identificadas ${#alertas[@]} situacoes que merecem atencao."
    fi
    echo ""
}

# ==========================================
# MÓDULO 2: TESTES DE CONECTIVIDADE (-p / -P)
# ==========================================
testar_conectividade() {
    local destino="$1"
    local tmp_ping="/tmp/netadmin_ping_$$.tmp"

    if ! command -v ping >/dev/null 2>&1; then
        echo "Erro: Comando 'ping' nao encontrado no sistema." >&2
        return 1
    fi

    LC_ALL=C ping -c 4 "$destino" > "$tmp_ping" 2>&1
    local status_ping=$?

    if grep -qiE "Name or service not known|Temporary failure|unknown host" "$tmp_ping"; then
        echo "=== TESTE DE CONECTIVIDADE ==="
        echo "Destino: $destino"
        echo "Resultado: FALHA (Nao foi possivel resolver o endereco)"
        echo ""
        rm -f "$tmp_ping"
        return 1
    fi

    local ip_resolvido
    ip_resolvido=$(head -n 1 "$tmp_ping" | grep -oE '\([0-9.]+\)' | head -n 1 | tr -d '()')
    [ -z "$ip_resolvido" ] && ip_resolvido="$destino"

    local linha_pacotes enviados recebidos perda
    linha_pacotes=$(grep "packets transmitted" "$tmp_ping")
    enviados=$(echo "$linha_pacotes" | awk '{print $1}')
    recebidos=$(echo "$linha_pacotes" | awk '{print $4}')
    perda=$(echo "$linha_pacotes" | grep -oE '[0-9]+(\.[0-9]+)?%')

    local linha_rtt t_min t_med t_max
    linha_rtt=$(grep -E "rtt|round-trip" "$tmp_ping")
    if [ -n "$linha_rtt" ]; then
        local valores_rtt
        valores_rtt=$(echo "$linha_rtt" | awk -F'=' '{print $2}' | awk '{print $1}')
        t_min=$(echo "$valores_rtt" | cut -d'/' -f1)
        t_med=$(echo "$valores_rtt" | cut -d'/' -f2)
        t_max=$(echo "$valores_rtt" | cut -d'/' -f3)
    else
        t_min="N/A"; t_med="N/A"; t_max="N/A"
    fi

    local resultado="FALHA"
    [ $status_ping -eq 0 ] && resultado="SUCESSO"

    if [ $MODO_DETALHADO -eq 1 ]; then
        echo "=== TESTE DE CONECTIVIDADE (MODO DETALHADO) ==="
        echo "Destino informado: $destino"
        echo "Endereco IP resolvido: $ip_resolvido"
        echo ""
        echo "EXECUCAO DO TESTE"
        for i in 1 2 3 4; do
            local tempo_seq
            tempo_seq=$(grep "icmp_seq=$i " "$tmp_ping" | grep -oE 'time=[0-9.]+' | cut -d'=' -f2)
            if [ -n "$tempo_seq" ]; then
                echo "Tentativa $i: RESPOSTA (${tempo_seq} ms)"
            else
                echo "Tentativa $i: SEM RESPOSTA"
            fi
        done
        echo ""
        echo "ESTATISTICAS"
        echo "Pacotes enviados: ${enviados:-4}"
        echo "Pacotes recebidos: ${recebidos:-0}"
        echo "Pacotes perdidos: $(( ${enviados:-4} - ${recebidos:-0} ))"
        echo "Perda: ${perda:-100%}"
        echo "Tempo minimo: ${t_min} ms"
        echo "Tempo medio: ${t_med} ms"
        echo "Tempo maximo: ${t_max} ms"
        echo "RESULTADO: $resultado"
    else
        echo "=== TESTE DE CONECTIVIDADE ==="
        echo "Destino: $destino"
        echo "Resultado: $resultado"
        echo "Pacotes enviados: ${enviados:-4}"
        echo "Pacotes recebidos: ${recebidos:-0}"
        echo "Perda: ${perda:-100%}"
        echo "Tempo medio: ${t_med} ms"
    fi
    echo ""

    rm -f "$tmp_ping"
}

testar_arquivo_destinos() {
    local arquivo="$1"

    if [ ! -f "$arquivo" ]; then
        echo "Erro: Arquivo '$arquivo' nao encontrado." >&2
        exit 1
    fi
    if [ ! -r "$arquivo" ]; then
        echo "Erro: Sem permissao de leitura no arquivo '$arquivo'." >&2
        exit 1
    fi

    while IFS= read -r linha || [ -n "$linha" ]; do
        [[ -z "$linha" || "$linha" =~ ^# ]] && continue
        testar_conectividade "$linha"
    done < "$arquivo"
}

# ==========================================
# MÓDULO 3: SERVIÇOS E PORTAS (-s / -c)
# ==========================================
listar_portas_escuta() {
    if ! command -v ss >/dev/null 2>&1; then
        echo "Erro: Comando 'ss' nao encontrado no sistema." >&2
        return 1
    fi

    local tmp_ss="/tmp/netadmin_ss_$$.tmp"
    LC_ALL=C ss -tuln | tail -n +2 > "$tmp_ss"

    local total_tcp=0
    local total_udp=0

    if [ $MODO_DETALHADO -eq 1 ]; then
        echo "=== SERVICOS E PORTAS LOCAIS (MODO DETALHADO) ==="
        echo "SOCKETS TCP"
        printf "%-10s | %-20s | %-10s\n" "PROTOCOLO" "ENDERECO LOCAL" "PORTA"
        while read -r proto state recv send local_addr peer_addr; do
            if [[ "$proto" == tcp* ]]; then
                local ip="${local_addr%:*}"
                local porta="${local_addr##*:}"
                printf "%-10s | %-20s | %-10s\n" "$proto" "$ip" "$porta"
                ((total_tcp++))
            fi
        done < "$tmp_ss"

        echo ""
        echo "SOCKETS UDP"
        printf "%-10s | %-20s | %-10s\n" "PROTOCOLO" "ENDERECO LOCAL" "PORTA"
        while read -r proto state recv send local_addr peer_addr; do
            if [[ "$proto" == udp* ]]; then
                local ip="${local_addr%:*}"
                local porta="${local_addr##*:}"
                printf "%-10s | %-20s | %-10s\n" "$proto" "$ip" "$porta"
                ((total_udp++))
            fi
        done < "$tmp_ss"

        echo ""
        echo "DETALHAMENTO"
        while read -r proto state recv send local_addr peer_addr; do
            local ip="${local_addr%:*}"
            local porta="${local_addr##*:}"
            if [[ "$ip" == "0.0.0.0" || "$ip" == "*" || "$ip" == "[::]" || "$ip" == "::" ]]; then
                echo "${ip}:${porta} ($proto) -> Escuta em todas as interfaces."
            else
                echo "${ip}:${porta} ($proto) -> Disponivel somente localmente."
            fi
        done < "$tmp_ss"

        echo ""
        echo "RESUMO"
        echo "Sockets TCP: $total_tcp"
        echo "Sockets UDP: $total_udp"
        echo "Total: $((total_tcp + total_udp))"
        echo ""
        echo "COMANDO UTILIZADO"
        echo "ss -tuln"
    else
        echo "=== SERVICOS E PORTAS LOCAIS ==="
        printf "%-10s | %-20s | %-10s\n" "PROTOCOLO" "ENDERECO LOCAL" "PORTA"
        local total=0
        while read -r proto state recv send local_addr peer_addr; do
            [ -z "$proto" ] && continue
            local ip="${local_addr%:*}"
            local porta="${local_addr##*:}"
            printf "%-10s | %-20s | %-10s\n" "$proto" "$ip" "$porta"
            ((total++))
        done < "$tmp_ss"
        echo ""
        echo "Total de sockets encontrados: $total"
    fi
    echo ""
    rm -f "$tmp_ss"
}

verificar_portas() {
    local lista_portas="$1"

    if ! command -v ss >/dev/null 2>&1; then
        echo "Erro: Comando 'ss' nao encontrado no sistema." >&2
        return 1
    fi

    local tmp_ss="/tmp/netadmin_ss_check_$$.tmp"
    LC_ALL=C ss -tuln | tail -n +2 > "$tmp_ss"

    echo "=== VERIFICACAO DE PORTAS ==="
    local encontradas=0
    local nao_encontradas=0

    for porta in $(echo "$lista_portas" | tr ',' ' '); do
        if ! [[ "$porta" =~ ^[0-9]+$ ]]; then
            echo "Porta $porta: INVALIDA (deve ser numerica)"
            ((nao_encontradas++))
            continue
        fi

        local proto_encontrado=""
        while read -r proto state recv send local_addr peer_addr; do
            local p_atual="${local_addr##*:}"
            if [ "$p_atual" == "$porta" ]; then
                proto_encontrado=$(echo "$proto" | tr '[:lower:]' '[:upper:]')
                break
            fi
        done < "$tmp_ss"

        if [ -n "$proto_encontrado" ]; then
            echo "Porta $porta: ABERTA ($proto_encontrado)"
            ((encontradas++))
        else
            echo "Porta $porta: NAO ENCONTRADA"
            ((nao_encontradas++))
        fi
    done

    echo "Resumo: $encontradas encontradas; $nao_encontradas nao encontrada(s)."
    echo ""
    rm -f "$tmp_ss"
}

# ==========================================
# MÓDULO 4: ANÁLISE DE ARQUIVOS DE LOG (-l)
# ==========================================
analisar_log() {
    local arquivo="$1"

    if [ ! -f "$arquivo" ]; then
        echo "Erro: Arquivo de log '$arquivo' nao encontrado." >&2
        exit 1
    fi
    if [ ! -r "$arquivo" ]; then
        echo "Erro: Sem permissao de leitura no arquivo '$arquivo'." >&2
        exit 1
    fi
    if [ ! -s "$arquivo" ]; then
        echo "Erro: O arquivo de log '$arquivo' esta vazio." >&2
        exit 1
    fi

    local tmp_validos="/tmp/netadmin_log_validos_$$.tmp"
    grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+.*" [0-9]{3} ' "$arquivo" > "$tmp_validos"

    local total_linhas total_validas linhas_invalidas
    total_linhas=$(wc -l < "$arquivo" | tr -d ' ')
    total_validas=$(wc -l < "$tmp_validos" | tr -d ' ')
    linhas_invalidas=$((total_linhas - total_validas))

    if [ "$total_validas" -eq 0 ]; then
        echo "Aviso: Nenhum registro HTTP valido encontrado em '$arquivo'."
        rm -f "$tmp_validos"
        return 1
    fi

    local codigos_tmp="/tmp/netadmin_codigos_$$.tmp"
    cut -d' ' -f9 "$tmp_validos" > "$codigos_tmp"

    if [ $MODO_DETALHADO -eq 1 ]; then
        echo "=== ANALISE DE LOG (MODO DETALHADO) ==="
        echo "Arquivo: $arquivo"
        echo "Registros processados: $total_validas"
        echo "Linhas invalidas: $linhas_invalidas"
        echo ""
        echo "RESPOSTAS HTTP POR CODIGO"
        sort "$codigos_tmp" | uniq -c | sort -k2 -n | while read -r qtd cod; do
            echo "$cod: $qtd"
        done

        local c2xx c3xx c4xx c5xx
        c2xx=$(grep -c '^2' "$codigos_tmp")
        c3xx=$(grep -c '^3' "$codigos_tmp")
        c4xx=$(grep -c '^4' "$codigos_tmp")
        c5xx=$(grep -c '^5' "$codigos_tmp")

        echo ""
        echo "CLASSIFICACAO"
        echo "2xx: $c2xx ($((c2xx * 100 / total_validas))%)"
        echo "3xx: $c3xx ($((c3xx * 100 / total_validas))%)"
        echo "4xx: $c4xx ($((c4xx * 100 / total_validas))%)"
        echo "5xx: $c5xx ($((c5xx * 100 / total_validas))%)"

        echo ""
        echo "REQUISICOES POR IP"
        cut -d' ' -f1 "$tmp_validos" | sort | uniq -c | sort -nr | while read -r qtd ip; do
            echo "$ip: $qtd"
        done

        echo ""
        echo "REQUISICOES POR RECURSO"
        cut -d' ' -f7 "$tmp_validos" | sort | uniq -c | sort -nr | while read -r qtd rec; do
            echo "$rec: $qtd"
        done

        echo ""
        echo "REQUISICOES POR METODO"
        cut -d' ' -f6 "$tmp_validos" | tr -d '"' | sort | uniq -c | sort -nr | while read -r qtd met; do
            echo "$met: $qtd"
        done

        echo ""
        echo "ERROS HTTP"
        echo "Respostas 4xx: $c4xx"
        echo "Respostas 5xx: $c5xx"
        echo "Total: $((c4xx + c5xx))"

        local primeira_hora ultima_hora
        primeira_hora=$(head -n 1 "$tmp_validos" | cut -d' ' -f4 | cut -d':' -f2-4)
        ultima_hora=$(tail -n 1 "$tmp_validos" | cut -d' ' -f4 | cut -d':' -f2-4)

        echo ""
        echo "HORARIO"
        echo "Primeira requisicao: ${primeira_hora:-N/A}"
        echo "Ultima requisicao: ${ultima_hora:-N/A}"
    else
        local c200 c404 c500
        c200=$(grep -c '^200$' "$codigos_tmp")
        c404=$(grep -c '^404$' "$codigos_tmp")
        c500=$(grep -c '^500$' "$codigos_tmp")

        echo "======================="
        echo "RELATORIO DE ACESSOS"
        echo "======================="
        echo "Total de requisicoes: $total_validas"
        echo ""
        echo "Respostas HTTP:"
        echo "200: $c200"
        echo "404: $c404"
        echo "500: $c500"
        echo ""
        echo "Enderecos com mais acessos:"
        cut -d' ' -f1 "$tmp_validos" | sort | uniq -c | sort -nr | head -n 3 | while read -r qtd ip; do
            echo "$ip: $qtd"
        done
    fi
    echo ""
    rm -f "$tmp_validos" "$codigos_tmp"
}

# ==========================================
# MÓDULO 5: ORQUESTRAÇÃO E RELATÓRIO (-o)
# ==========================================
executar_auditoria() {
    if [ -n "$ARQUIVO_SAIDA" ]; then
        echo "=================================================="
        echo "RELATORIO DE AUDITORIA - NETADMIN"
        echo "Servidor: $(hostname)"
        echo "Data/Hora: $(date '+%d/%m/%Y %H:%M:%S')"
        echo "=================================================="
        echo ""
    fi

    [ $EXECUTAR_INFO -eq 1 ] && diagnostico_rede
    [ -n "$DESTINO_PING" ] && testar_conectividade "$DESTINO_PING"
    [ -n "$ARQUIVO_PING" ] && testar_arquivo_destinos "$ARQUIVO_PING"
    [ $LISTAR_PORTAS -eq 1 ] && listar_portas_escuta
    [ -n "$PORTAS_CHECK" ] && verificar_portas "$PORTAS_CHECK"
    [ -n "$ARQUIVO_LOG" ] && analisar_log "$ARQUIVO_LOG"
}

# Leitura das opções com getopts
while getopts ":ip:P:sc:l:o:vh" opt; do
    case $opt in
        i) EXECUTAR_INFO=1 ;;
        p) DESTINO_PING="$OPTARG" ;;
        P) ARQUIVO_PING="$OPTARG" ;;
        s) LISTAR_PORTAS=1 ;;
        c) PORTAS_CHECK="$OPTARG" ;;
        l) ARQUIVO_LOG="$OPTARG" ;;
        o) ARQUIVO_SAIDA="$OPTARG" ;;
        v) MODO_DETALHADO=1 ;;
        h) mostrar_ajuda; exit 0 ;;
        :) echo "Erro: A opcao -$OPTARG exige um argumento." >&2; exit 1 ;;
        \?) echo "Erro: Opcao invalida -$OPTARG" >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

# Se nenhuma opção de ação foi passada, mostra ajuda
if [ $EXECUTAR_INFO -eq 0 ] && [ -z "$DESTINO_PING" ] && [ -z "$ARQUIVO_PING" ] && \
   [ $LISTAR_PORTAS -eq 0 ] && [ -z "$PORTAS_CHECK" ] && [ -z "$ARQUIVO_LOG" ]; then
    mostrar_ajuda
    exit 1
fi

# Validação do arquivo de saída (-o) antes de executar
if [ -n "$ARQUIVO_SAIDA" ]; then
    dir_saida=$(dirname "$ARQUIVO_SAIDA")
    if [ ! -d "$dir_saida" ]; then
        echo "Erro: O diretorio de destino '$dir_saida' nao existe." >&2
        exit 1
    fi
    if [ ! -w "$dir_saida" ]; then
        echo "Erro: Sem permissao de escrita no diretorio '$dir_saida'." >&2
        exit 1
    fi
    executar_auditoria | tee "$ARQUIVO_SAIDA"
else
    executar_auditoria
fi
