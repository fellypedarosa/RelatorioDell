#requires -Version 5.1
<#
.SYNOPSIS
Gera um CSV de pendências Dell sem instalar atualizações.
.DESCRIPTION
Consulta o inventário local do DSU e os downloads publicados no site Dell.
Também permite consultar um catálogo explícito, verificando a cobertura do modelo.
Compatível com Windows PowerShell 5.1. Execute como administrador.
.PARAMETER CaminhoSaida
Pasta local ou UNC. O padrão é a subpasta Relatorios junto deste script.
.PARAMETER CaminhoDSU
Caminho completo opcional de DSU.exe, caso a descoberta automática não o localize.
.PARAMETER Fonte
Site (padrão): compara o inventário com os downloads publicados no site Dell.
Catalogo: usa o preview do DSU com um catálogo e exige cobertura do modelo no XML.
.PARAMETER ConsultaSite
Modelo (padrão): consulta os downloads pelo modelo e pelo Windows Server instalado.
ServiceTag é uma opção experimental, sem sucesso online confirmado; a Dell pode
bloquear esse acesso automatizado com HTTP 403.
.PARAMETER ArquivoInventario
Reutiliza um inventário XML SVMInventory ou texto do DSU deste mesmo servidor.
O texto precisa conter Exiting DSU!; o XML precisa estar completo e válido.
Válido para Fonte Site; evita repetir uma consulta demorada do DSU.
.PARAMETER ArquivoSiteDell
Importa os downloads de um arquivo .har exportado manualmente do Edge ou Chrome.
Substitui a consulta online ao site, mantendo o inventário e a comparação locais.
O HAR precisa conter a resposta de downloads do modelo e Windows deste servidor.
Não combine com Catalogo. Consulte docs/Importacao-Manual-Dell.md para capturar.
.PARAMETER CodigoProduto
Código opcional do produto na URL Dell, por exemplo poweredge-r530.
.PARAMETER CodigoSO
Código opcional do SO na URL Dell. Por padrão é identificado pelo Windows instalado.
.PARAMETER Catalogo
URL HTTPS ou arquivo local/UNC .xml.gz, .gz ou .xml de um catálogo atualizado.
As assinaturas disponíveis devem acompanhar o catálogo local. Informar este
parâmetro sem Fonte seleciona automaticamente o modo Catalogo.
#>
[CmdletBinding()]
param(
    [string]$CaminhoSaida,
    [string]$CaminhoDSU,
    [ValidateSet('Site', 'Catalogo')][string]$Fonte = 'Site',
    [ValidateSet('ServiceTag', 'Modelo')][string]$ConsultaSite = 'Modelo',
    [string]$ArquivoInventario,
    [ValidateNotNullOrEmpty()][string]$ArquivoSiteDell,
    [string]$CodigoProduto,
    [string]$CodigoSO,
    [string]$Catalogo = 'https://downloads.dell.com/catalog/Catalog.xml.gz',
    [ValidateRange(1, 180)][int]$TempoLimiteDSUMinutos = 10
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:ArquivoLog = $null
$script:Diagnostico = $null

function Write-Log {
    param([string]$Mensagem, [ValidateSet('INFO', 'AVISO', 'ERRO')][string]$Nivel = 'INFO')
    $linha = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Nivel, $Mensagem
    Write-Host $linha
    if ($script:ArquivoLog) {
        Add-Content -LiteralPath $script:ArquivoLog -Value $linha -Encoding UTF8
    }
}

function Find-DsuExecutable {
    param([string]$Informado)
    if ($Informado) {
        if (-not (Test-Path -LiteralPath $Informado -PathType Leaf)) {
            throw "DSU não encontrado em '$Informado'. Informe o caminho completo de DSU.exe."
        }
        $arquivo = Get-Item -LiteralPath $Informado
        if ($arquivo.Extension -ine '.exe') { throw 'CaminhoDSU deve apontar para um executável .exe.' }
        return $arquivo.FullName
    }
    $comando = Get-Command 'dsu.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($comando) { return $comando.Source }
    foreach ($raiz in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData)) {
        if (-not $raiz) { continue }
        foreach ($pasta in @('Dell\DELL System Update', 'Dell\DELLSystemUpdate', 'Dell\DELL EMC System Update', 'Dell\Dell System Update')) {
            $candidato = Join-Path $raiz (Join-Path $pasta 'dsu.exe')
            if (Test-Path -LiteralPath $candidato -PathType Leaf) { return $candidato }
        }
    }
    throw 'DSU não instalado ou não localizado. Instale o Dell System Update para Windows ou informe -CaminhoDSU.'
}

function ConvertTo-NativeArgument {
    param([string]$Valor)
    # Escape das aspas e barras conforme as regras de argumentos do Windows; não usa shell.
    $escapado = $Valor -replace '(\\*)"', '$1$1\"'
    $escapado = $escapado -replace '(\\+)$', '$1$1'
    return '"' + $escapado + '"'
}

function Invoke-DsuReadOnly {
    param([string]$Executavel, [string[]]$Argumentos, [string]$Etapa, [int]$LimiteMinutos = 30)
    # Esta função só é chamada com --help, --inventory ou --preview.
    $inicio = New-Object System.Diagnostics.ProcessStartInfo
    $inicio.FileName = $Executavel
    $inicio.Arguments = (@($Argumentos | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $inicio.WorkingDirectory = Split-Path -Parent $Executavel
    $inicio.UseShellExecute = $false
    $inicio.CreateNoWindow = $true
    $inicio.RedirectStandardOutput = $true
    $inicio.RedirectStandardError = $true
    $inicio.RedirectStandardInput = $true
    $processo = New-Object System.Diagnostics.Process
    $processo.StartInfo = $inicio
    Write-Log ("DSU/{0}: {1}" -f $Etapa, ($Argumentos -join ' '))
    try {
        [void]$processo.Start()
        $processo.StandardInput.Close()
        # Leitura simultânea evita travamento se stdout ou stderr encher o buffer.
        $saidaTask = $processo.StandardOutput.ReadToEndAsync()
        $erroTask = $processo.StandardError.ReadToEndAsync()
        $relogio = [Diagnostics.Stopwatch]::StartNew()
        $proximoAviso = 15
        while (-not $processo.WaitForExit(1000)) {
            if ($relogio.Elapsed.TotalMinutes -ge $LimiteMinutos) {
                $processo.Kill()
                [void]$processo.WaitForExit(5000)
                throw "DSU/$Etapa excedeu $LimiteMinutos minuto(s). Verifique processos e logs do DSU antes de repetir."
            }
            if ($relogio.Elapsed.TotalSeconds -ge $proximoAviso) {
                Write-Log ("DSU/{0} continua em execução ({1:mm\:ss}). Aguardando o processo encerrar." -f $Etapa, $relogio.Elapsed)
                $proximoAviso += 15
            }
        }
        # Um processo auxiliar pode manter o pipe aberto após a saída do DSU.
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($saidaTask, $erroTask), 10000)) {
            throw "O DSU/$Etapa encerrou, mas a captura de saída não terminou em 10 segundos. Verifique seus processos auxiliares."
        }
        $saida = $saidaTask.GetAwaiter().GetResult()
        $erro = $erroTask.GetAwaiter().GetResult()
        [IO.File]::WriteAllText((Join-Path $script:Diagnostico "$Etapa.stdout.txt"), $saida, (New-Object Text.UTF8Encoding($true)))
        [IO.File]::WriteAllText((Join-Path $script:Diagnostico "$Etapa.stderr.txt"), $erro, (New-Object Text.UTF8Encoding($true)))
        $codigo = $processo.ExitCode
        Write-Log "DSU/$Etapa concluído; código de saída $codigo."
        return [pscustomobject]@{ Text = ($saida + "`n" + $erro); ExitCode = $codigo }
    }
    finally { $processo.Dispose() }
}

function Assert-DsuHelp {
    param([string]$Texto)
    # Não adivinha opções em versões que não anunciam as três operações esperadas.
    foreach ($opcao in @('--preview', '--catalog-location', '--inventory')) {
        if ($Texto -notmatch ('(?im)(?<![\w-])' + [regex]::Escape($opcao) + '(?=[\s=,\[\]<>;:]|$)')) {
            throw "A ajuda desta versão não anuncia '$opcao'. Consulte help.stdout.txt e ajuste Get-DsuArguments conforme o --help instalado."
        }
    }
}

function Get-DsuArguments {
    param([ValidateSet('Inventario', 'Preview')][string]$Modo, [string]$CatalogoLocal)
    # PONTO DE ADAPTAÇÃO: sintaxe longa documentada pela Dell, validada no --help.
    # Nunca adicionar --non-interactive: isoladamente essa opção pode instalar updates.
    if ($Modo -eq 'Inventario') { return @('--inventory') }
    return @('--preview', ('--catalog-location=' + $CatalogoLocal))
}

function Get-CatalogSnapshot {
    param([string]$Origem, [string]$Pasta)
    $uri = $null
    $remoto = [Uri]::TryCreate($Origem, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -in @('https', 'http')
    if ($remoto -and $uri.Scheme -ne 'https') { throw 'Use HTTPS para baixar o catálogo.' }
    $nome = if ($remoto) { [IO.Path]::GetFileName($uri.AbsolutePath) } else { Split-Path -Leaf $Origem }
    if ($nome -notmatch '(?i)\.(gz|xml)$') { throw 'Catalogo deve ser um arquivo .gz ou .xml (catálogos CAB/índices não são aceitos por este script).' }
    $destino = Join-Path $Pasta $nome
    Write-Log "Obtendo catálogo: $Origem"
    if ($remoto) {
        try {
            Invoke-WebRequest -Uri $Origem -OutFile $destino -UseBasicParsing -TimeoutSec 180 -ErrorAction Stop
        }
        catch {
            throw "Não foi possível baixar o catálogo. Verifique internet, DNS, proxy, TLS e acesso a '$Origem'. Detalhe: $($_.Exception.Message)"
        }
    }
    else {
        if (-not (Test-Path -LiteralPath $Origem -PathType Leaf)) { throw "Catálogo local/UNC inacessível: $Origem" }
        Copy-Item -LiteralPath $Origem -Destination $destino
        $idade = ((Get-Date) - (Get-Item -LiteralPath $Origem).LastWriteTime).Days
        Write-Log "Catálogo fornecido pelo operador; arquivo modificado há $idade dia(s). A atualização da fonte é responsabilidade do operador."
    }
    # Preserva assinaturas para a validação do próprio DSU. Não ignora assinatura/certificado.
    foreach ($sufixo in @('.sign', '.sha512.sign')) {
        if ($remoto) {
            $assinaturaUri = New-Object UriBuilder($uri)
            $assinaturaUri.Path += $sufixo
            try {
                Invoke-WebRequest -Uri $assinaturaUri.Uri.AbsoluteUri -OutFile ($destino + $sufixo) -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
            }
            catch { Write-Log "Assinatura $sufixo indisponível; o DSU decidirá se o catálogo pode ser validado. $($_.Exception.Message)" 'AVISO' }
        }
        elseif (Test-Path -LiteralPath ($Origem + $sufixo) -PathType Leaf) {
            Copy-Item -LiteralPath ($Origem + $sufixo) -Destination ($destino + $sufixo)
        }
    }
    $xmlPath = $destino
    if ($nome -match '(?i)\.gz$') {
        $xmlPath = Join-Path $Pasta 'CatalogoExtraido.xml'
        $entrada = $gzip = $saida = $null
        try {
            $entrada = [IO.File]::OpenRead($destino)
            $gzip = New-Object IO.Compression.GZipStream($entrada, [IO.Compression.CompressionMode]::Decompress)
            $saida = [IO.File]::Create($xmlPath)
            $gzip.CopyTo($saida)
        }
        catch { throw "Catálogo GZip inválido ou impossível de descompactar: $($_.Exception.Message)" }
        finally {
            if ($saida) { $saida.Dispose() }
            if ($gzip) { $gzip.Dispose() }
            if ($entrada) { $entrada.Dispose() }
        }
    }
    $hash = (Get-FileHash -LiteralPath $destino -Algorithm SHA256).Hash
    Write-Log "Snapshot do catálogo SHA256=$hash"
    @("Origem=$Origem", "SHA256=$hash", "ColetadoEm=$((Get-Date).ToString('o'))") |
        Set-Content -LiteralPath (Join-Path $script:Diagnostico 'catalogo.txt') -Encoding UTF8
    return [pscustomobject]@{ DsuPath = $destino; XmlPath = $xmlPath }
}

function Get-DisplayText {
    param([System.Xml.XmlNode]$No)
    if ($null -eq $No) { return '' }
    $display = $No.SelectSingleNode('./*[local-name()="Display" and (@lang="en" or @lang="en-us")]')
    if (-not $display) { $display = $No.SelectSingleNode('./*[local-name()="Display"]') }
    if ($display) { return $display.InnerText.Trim() }
    return ''
}

function ConvertTo-CriticalityLabel {
    param([string]$Texto)
    switch -Regex ($Texto.Trim()) {
        '^(Urgent|Urgente)$' { return 'Urgente' }
        '^(Recommended|Recomendado|Recomendada)$' { return 'Recomendado' }
        '^(Optional|Opcional)$' { return 'Opcional' }
        default { return '' }
    }
}

function Get-PackageKey {
    param([string]$Nome)
    # Apenas normaliza diretório, caixa e extensão EXE; nunca usa nome aproximado.
    return (($Nome.Trim().Trim('"') -split '[\\/]')[-1] -replace '(?i)\.exe$', '').ToLowerInvariant()
}

function Read-DellCatalog {
    param([string]$Arquivo)
    $config = New-Object Xml.XmlReaderSettings
    $config.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $config.XmlResolver = $null
    $reader = [Xml.XmlReader]::Create($Arquivo, $config)
    $pacotes = New-Object 'System.Collections.Generic.List[object]'
    $mapa = @{}
    try {
        # Leitura por componente funciona também com namespace e XML UTF-16.
        while ($reader.Read()) {
            if ($reader.NodeType -eq [Xml.XmlNodeType]::Element -and $reader.LocalName -eq 'Manifest') {
                Write-Log ("Manifest do catálogo: versão={0}; data={1}." -f $reader.GetAttribute('version'), $reader.GetAttribute('dateTime'))
            }
            if ($reader.NodeType -ne [Xml.XmlNodeType]::Element -or $reader.LocalName -ne 'SoftwareComponent') { continue }
            $sub = $reader.ReadSubtree()
            try {
                $doc = New-Object Xml.XmlDocument
                $doc.XmlResolver = $null
                $doc.Load($sub)
            }
            finally { $sub.Close() }
            $no = $doc.DocumentElement
            $crit = $no.SelectSingleNode('./*[local-name()="Criticality"]')
            $codigo = if ($crit) { $crit.GetAttribute('value') } else { '' }
            $rotulo = ConvertTo-CriticalityLabel (Get-DisplayText $crit)
            if ($codigo -and $rotulo) {
                if ($mapa.ContainsKey($codigo) -and $mapa[$codigo] -ne $rotulo) { throw "Catálogo inconsistente: Criticality=$codigo tem significados diferentes." }
                $mapa[$codigo] = $rotulo
            }
            $tipo = $no.SelectSingleNode('./*[local-name()="ComponentType"]')
            $categoria = $no.SelectSingleNode('./*[local-name()="Category"]')
            $path = $no.GetAttribute('path')
            $data = $no.GetAttribute('releaseDate')
            $dataConvertida = [datetime]::MinValue
            if ([datetime]::TryParse($data, [Globalization.CultureInfo]::GetCultureInfo('en-US'), [Globalization.DateTimeStyles]::None, [ref]$dataConvertida)) {
                $data = $dataConvertida.ToString('yyyy-MM-dd')
            }
            $pacotes.Add([pscustomobject]@{
                Key = Get-PackageKey $path
                Nome = Get-DisplayText ($no.SelectSingleNode('./*[local-name()="Name"]'))
                Arquivo = ($path -split '[\\/]')[-1]
                Categoria = Get-DisplayText $categoria
                Tipo = if ($tipo) { $tipo.GetAttribute('value') } else { '' }
                VendorVersion = $no.GetAttribute('vendorVersion')
                ReleaseID = $no.GetAttribute('releaseID')
                Data = $data
                CodigoCriticidade = $codigo
                Criticidade = $rotulo
            })
        }
    }
    finally { $reader.Close() }
    if ($pacotes.Count -eq 0) { throw 'XML sem SoftwareComponent: catálogo inválido ou catálogo de índice. Forneça o catálogo de componentes.' }
    $indice = @{}
    foreach ($pacote in $pacotes) {
        # Um código sem Display só é traduzido se seu significado foi observado neste XML.
        if (-not $pacote.Criticidade) {
            $pacote.Criticidade = if ($mapa.ContainsKey($pacote.CodigoCriticidade)) { $mapa[$pacote.CodigoCriticidade] } else { 'Não informada' }
        }
        if ($pacote.Key) {
            if (-not $indice.ContainsKey($pacote.Key)) { $indice[$pacote.Key] = New-Object 'System.Collections.Generic.List[object]' }
            $indice[$pacote.Key].Add($pacote)
        }
    }
    Write-Log ("Catálogo lido: {0} componentes. Mapa observado: {1}" -f $pacotes.Count, (($mapa.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '))
    return $indice
}

function Get-DsuTextLines {
    param([string]$Texto)
    $textoLimpo = $Texto -replace '\x1B\[[0-?]*[ -/]*[@-~]', ''
    foreach ($linha in ($textoLimpo -split '\r?\n')) {
        # Algumas versões prefixam cada linha com [PID]:.
        ($linha -replace '^\s*\[\d+\]:\s*', '').Replace([char]0xA0, [char]0x20).Trim()
    }
}

function ConvertFrom-DsuPreviewText {
    param([string]$Texto, [int]$ExitCode)
    # PONTO DE ADAPTAÇÃO: aceita tabelas '# : [Type :] Component : Version : Filename'.
    if ($ExitCode -notin @(0, 34)) { throw "Preview DSU falhou (código $ExitCode). Consulte preview.stdout.txt e preview.stderr.txt." }
    $linhas = @(Get-DsuTextLines $Texto)
    if (($linhas -join "`n") -match '(?im)^\s*(?:ERROR\b|FATAL\b|Failed\b|Unable\b|Could\s+not\b)') {
        throw 'O preview contém uma mensagem de falha, apesar do código de saída. Consulte as saídas brutas do DSU.'
    }
    $cabecalho = $null
    $registros = New-Object 'System.Collections.Generic.List[string]'
    $atual = ''
    $emTabela = $false
    foreach ($linha in $linhas) {
        if ($linha -match '^#\s*:\s*(?:Type\s*:\s*)?Component\s*:\s*Version\s*:\s*Filename\s*$') {
            if ($null -ne $cabecalho) { throw 'Mais de uma tabela no preview. Adapte o parser antes de consolidar a saída.' }
            $cabecalho = @($linha -split '\s*:\s*')
            $emTabela = $true
            continue
        }
        if (-not $emTabela) {
            if ($linha -match '^(?:#|\d+)\s*:') { throw "Tabela/registro de preview fora do formato esperado: $linha" }
            continue
        }
        if ($linha -match '^\d+\s*:') {
            if ($atual) { $registros.Add($atual) }
            $atual = $linha
        }
        elseif ($linha -match '^(NOTE\b|Run\s+--|Exiting\b|Progress report\b|No (?:applicable )?updates\b)') {
            if ($atual) { $registros.Add($atual); $atual = '' }
            $emTabela = $false
        }
        elseif ($linha -and $linha -notmatch '^[-=]+$') {
            if ($atual) {
                # Não insere espaço ao recompor um Filename quebrado em duas linhas.
                $partesAtuais = @($atual -split '\s*:\s*')
                if ($partesAtuais.Count -eq $cabecalho.Count -and $linha -match '^[A-Za-z0-9_.-]+$') { $atual += $linha }
                else { $atual += ' ' + $linha }
            }
            else { throw "Linha não reconhecida no preview: $linha" }
        }
    }
    if ($atual) { $registros.Add($atual) }
    $itens = New-Object 'System.Collections.Generic.List[object]'
    foreach ($registro in $registros) {
        $campos = @($registro -split '\s*:\s*')
        if ($campos.Count -ne $cabecalho.Count) { throw "Linha de preview fora do formato esperado: $registro" }
        $offset = if ($cabecalho.Count -eq 5) { 1 } else { 0 }
        $nome = $campos[1 + $offset].Trim()
        $versao = $campos[2 + $offset].Trim()
        $arquivo = $campos[3 + $offset].Trim()
        if (-not $nome -or -not $versao -or -not $arquivo -or $arquivo -match '\s') { throw "Registro incompleto ou pacote inválido no preview: $registro" }
        $itens.Add([pscustomobject]@{ Nome = $nome; VersaoNova = $versao; Pacote = $arquivo })
    }
    $mensagemVazia = ($linhas -join "`n") -match '(?im)^\s*(?:No applicable updates(?: found| available)?|No updates (?:are )?(?:available|found)|(?:The )?[Ss]ystem is (?:already )?up[- ]to[- ]date)\s*[.!]?\s*$'
    if ($itens.Count -gt 0 -and ($ExitCode -eq 34 -or $mensagemVazia)) { throw 'Preview contraditório: contém pacotes e também sinaliza ausência de atualizações.' }
    if ($itens.Count -eq 0 -and $ExitCode -ne 34 -and -not $mensagemVazia) {
        throw 'Preview vazio ou formato desconhecido. Não é seguro concluir que não há pendências. Ajuste ConvertFrom-DsuPreviewText usando as saídas brutas.'
    }
    return [pscustomobject]@{ Itens = @($itens.ToArray()); SemPendencias = ($itens.Count -eq 0) }
}

function ConvertFrom-DsuInventoryText {
    param([string]$Texto)
    # PONTO DE ADAPTAÇÃO: 'N. [FRMW, ]Componente ( Version : instalada )'.
    foreach ($linha in (Get-DsuTextLines $Texto)) {
        if ($linha -match '^\d+[.)]\s*(?:(?<tipo>FRMW|BIOS|DRVR|APAC|APP|EAPP)\s*,\s*)?(?<nome>.+?)\s*\(\s*Version\s*:\s*(?<versao>[^)]+?)\s*\)\s*$') {
            [pscustomobject]@{ Nome = $Matches.nome.Trim(); Tipo = $Matches['tipo']; Versao = $Matches.versao.Trim() }
        }
    }
}

function Resolve-InstalledVersion {
    param([object[]]$Inventario, [string]$Nome, [string]$Tipo)
    # Associação exata de nome e tipo; não confunde firmware e driver da mesma NIC.
    $chave = ($Nome.Trim() -replace '\s+', ' ').ToLowerInvariant()
    $achados = @($Inventario | Where-Object {
        (($_.Nome.Trim() -replace '\s+', ' ').ToLowerInvariant() -eq $chave) -and
        (-not $_.Tipo -or $_.Tipo -eq $Tipo)
    })
    $versoes = @($achados | Select-Object -ExpandProperty Versao -Unique)
    if ($versoes.Count -eq 0) {
        Write-Log "Versão instalada não identificada para '$Nome' ($Tipo). Consulte inventory.stdout.txt e o parser do inventário." 'AVISO'
        return 'Não identificada'
    }
    if ($versoes.Count -gt 1) {
        Write-Log "Há múltiplas versões instaladas para '$Nome' ($Tipo): $($versoes -join ' | '). Não é possível atribuir cada instância pelo preview textual." 'AVISO'
        return ('Múltiplas: ' + ($versoes -join ' | '))
    }
    return $versoes[0]
}

function New-DellReportRows {
    param([object[]]$Pendencias, [hashtable]$Indice, [object[]]$Inventario, [string]$Hostname, [string]$ServiceTag, [string]$Modelo)
    foreach ($pendencia in $Pendencias) {
        $chave = Get-PackageKey $pendencia.Pacote
        if (-not $Indice.ContainsKey($chave)) {
            throw "Pacote '$($pendencia.Pacote)' ausente do catálogo usado. Nenhuma associação aproximada foi feita; revise preview e catálogo."
        }
        $candidatos = @($Indice[$chave].ToArray())
        if ($candidatos.Count -gt 1) { $candidatos = @($candidatos | Where-Object { $_.VendorVersion -eq $pendencia.VersaoNova }) }
        if ($candidatos.Count -ne 1) { throw "Associação ambígua do pacote '$($pendencia.Pacote)' ao catálogo." }
        $pacote = $candidatos[0]
        # Escopo: BIOS, firmware de qualquer dispositivo e drivers Dell. Exclui aplicativos.
        if ($pacote.Tipo -notin @('BIOS', 'FRMW', 'DRVR')) {
            Write-Log "Item fora do escopo firmware/drivers: $($pendencia.Nome) ($($pacote.Tipo))."
            continue
        }
        if ($pacote.Criticidade -eq 'Não informada') { Write-Log "Criticidade não informada no XML para $($pacote.Arquivo)." 'AVISO' }
        [pscustomobject][ordered]@{
            Hostname = $Hostname
            ServiceTag = $ServiceTag
            Modelo = $Modelo
            Componente = $pendencia.Nome
            Categoria = $pacote.Categoria
            VersaoAtual = Resolve-InstalledVersion $Inventario $pendencia.Nome $pacote.Tipo
            VersaoNova = $pendencia.VersaoNova
            Criticidade = $pacote.Criticidade
            DataDeLancamento = $pacote.Data
            NomeDoPacote = $pacote.Arquivo
        }
    }
}

function Export-DellReport {
    param([object[]]$Linhas, [string]$Arquivo, [string]$Hostname, [string]$ServiceTag, [string]$Modelo)
    if ($Linhas.Count -eq 0) {
        $Linhas = @([pscustomobject][ordered]@{
            Hostname = $Hostname; ServiceTag = $ServiceTag; Modelo = $Modelo
            Componente = 'Nenhuma atualização pendente'; Categoria = ''; VersaoAtual = ''
            VersaoNova = ''; Criticidade = ''; DataDeLancamento = ''; NomeDoPacote = ''
        })
    }
    $ordem = @{ Urgente = 1; Recomendado = 2; Opcional = 3 }
    $ordenadas = @($Linhas | Sort-Object @{ Expression = { if ($ordem.ContainsKey($_.Criticidade)) { $ordem[$_.Criticidade] } else { 4 } } }, Componente, NomeDoPacote)
    # BOM explícito para manter o formato mesmo se executado em outra edição do PowerShell.
    $conteudo = @($ordenadas | ConvertTo-Csv -Delimiter ';' -NoTypeInformation)
    [IO.File]::WriteAllLines(($Arquivo + '.tmp'), [string[]]$conteudo, (New-Object Text.UTF8Encoding($true)))
    Move-Item -LiteralPath ($Arquivo + '.tmp') -Destination $Arquivo
}

function Get-ObjectValue {
    param($Objeto, [string]$Nome)
    if ($null -eq $Objeto) { return $null }
    $propriedade = $Objeto.PSObject.Properties[$Nome]
    if ($null -ne $propriedade) { return $propriedade.Value }
    return $null
}

function Get-DellProductCode {
    param([string]$Modelo, [string]$Informado)
    if ($Informado) {
        if ($Informado -notmatch '^poweredge-[a-z0-9-]+$') { throw 'CodigoProduto inválido. Exemplo: poweredge-r530.' }
        return $Informado.ToLowerInvariant()
    }
    if ($Modelo -notmatch '(?i)^PowerEdge\s+(?<modelo>[a-z0-9]+(?:\s+[a-z0-9]+)*)$') {
        throw "Não foi possível identificar o código Dell do modelo '$Modelo'. Informe -CodigoProduto conforme a URL do site."
    }
    return 'poweredge-' + ($Matches['modelo'] -replace '\s+', '').ToLowerInvariant()
}

function Get-DellOsCode {
    param([string]$Legenda, [string]$Informado)
    if ($Informado) {
        if ($Informado -notmatch '^[A-Za-z0-9]{3,10}$') { throw 'CodigoSO inválido.' }
        return $Informado.ToUpperInvariant()
    }
    if ($Legenda -notmatch '(?i)Windows Server\s+(?<ano>2008|2012|2016|2019|2022|2025)(?<r2>\s+R2)?\b') {
        throw "Windows Server não reconhecido: '$Legenda'. Informe -CodigoSO conforme o site Dell."
    }
    $chave = $Matches['ano']
    if ($Matches['r2']) { $chave += 'R2' }
    $mapa = @{ '2008R2' = 'WS8R2'; '2012' = 'WSS12'; '2012R2' = 'W12R2'; '2016' = 'WST14'; '2019' = 'WS19L'; '2022' = 'WS22L'; '2025' = 'WS25L' }
    if (-not $mapa.ContainsKey($chave)) { throw "SO sem código Dell conhecido: $Legenda. Informe -CodigoSO." }
    return $mapa[$chave]
}

function ConvertFrom-DellSiteResponse {
    param([string]$Texto, [string]$Produto, [switch]$ExigirTag, [string]$ServiceTag, [string]$TokenTag)
    # O site publica dndDecrypt no seu JavaScript. A transformação vigente é
    # uma rotação das letras ASCII. Aceita JSON aberto e valida o schema/produto.
    # Tentar as rotações evita depender exclusivamente do valor 3 observado.
    $raiz = $null
    foreach ($deslocamento in (@(0, 3, 1, 2) + @(4..25))) {
        $candidato = $Texto
        if ($deslocamento -gt 0) {
            $builder = New-Object Text.StringBuilder($Texto.Length)
            foreach ($letra in $Texto.ToCharArray()) {
                $numero = [int]$letra
                if ($numero -ge 65 -and $numero -le 90) { $letra = [char](($numero - 65 - $deslocamento + 26) % 26 + 65) }
                elseif ($numero -ge 97 -and $numero -le 122) { $letra = [char](($numero - 97 - $deslocamento + 26) % 26 + 97) }
                [void]$builder.Append($letra)
            }
            $candidato = $builder.ToString()
        }
        # Evita executar ConvertFrom-Json para rotações que nem contêm o schema.
        if ($candidato -notmatch '"DriverListData"\s*:') { continue }
        try { $objeto = ConvertFrom-Json -InputObject $candidato -ErrorAction Stop }
        catch { continue }
        if ($null -ne $objeto.PSObject.Properties['DriverListData']) {
            $raiz = $objeto
            break
        }
    }
    if ($null -eq $raiz) { throw 'O site Dell não retornou o JSON de downloads esperado. Pode ser bloqueio de acesso ou alteração da API interna; nenhuma ausência de pendências foi presumida.' }
    if ([string](Get-ObjectValue $raiz 'ProductCode') -ine $Produto) { throw 'O produto retornado pela API Dell não corresponde ao modelo consultado.' }
    $lista = @(Get-ObjectValue $raiz 'DriverListData')
    if ($lista.Count -eq 0 -or $null -eq $lista[0]) { throw 'A API retornou uma lista de downloads vazia. A verificação é inconclusiva.' }
    foreach ($item in $lista) {
        foreach ($campo in @('DriverId', 'DriverName', 'Type', 'DellVer', 'ReleaseDate')) {
            if ([string]::IsNullOrWhiteSpace([string](Get-ObjectValue $item $campo))) { throw "Resposta Dell incompleta: falta '$campo' em um download." }
        }
        if ([string](Get-ObjectValue $item 'DriverId') -notmatch '^[A-Za-z0-9]{5}$') { throw 'DriverId inválido na resposta Dell.' }
    }
    if ($ExigirTag) {
        $isTag = Get-ObjectValue $raiz 'IsTag'
        if ($isTag -isnot [bool] -or -not $isTag) { throw 'A resposta Dell não confirmou a consulta por Service Tag. Não foi usada a lista ampla do modelo.' }
        $semTag = Get-ObjectValue $raiz 'IsNoDriversFoundForTag'
        if ($semTag -isnot [bool] -or $semTag) { throw 'A Dell não confirmou downloads para esta Service Tag. Verificação inconclusiva.' }
        $identidade = [string](Get-ObjectValue $raiz 'ServiceTag')
        $tagConfere = $ServiceTag -and $identidade.Equals($ServiceTag.Trim(), [StringComparison]::OrdinalIgnoreCase)
        $tokenConfere = $TokenTag -and [Uri]::UnescapeDataString($identidade).Equals([Uri]::UnescapeDataString($TokenTag), [StringComparison]::Ordinal)
        if (-not $tagConfere -and -not $tokenConfere) { throw 'A identidade retornada pela Dell não corresponde à Service Tag consultada.' }
        $filtrados = New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in $lista) {
            $marcacao = [int]0
            if (-not [int]::TryParse([string](Get-ObjectValue $item 'IsTagDriver'), [ref]$marcacao) -or $marcacao -lt 0) {
                throw 'A resposta Dell não contém marcações IsTagDriver válidas. Não é seguro assumir o filtro por tag.'
            }
            if ($marcacao -gt 0) { $filtrados.Add($item) }
        }
        if ($filtrados.Count -eq 0) { throw 'Nenhum registro foi marcado pela Dell para esta Service Tag. Verificação inconclusiva.' }
        $raiz | Add-Member -NotePropertyName TotalDownloadsRecebidos -NotePropertyValue $lista.Count -Force
        $raiz.DriverListData = @($filtrados.ToArray())
    }
    return $raiz
}

function Get-DellTagToken {
    param([string]$Html, [Uri]$UrlFinal)
    # A página fornece o identificador usado como encryptedServiceTag no JS.
    # Não tenta fabricar/descriptografar esse identificador nem executar scripts.
    if ($null -eq $UrlFinal -or $UrlFinal.Scheme -ne 'https' -or $UrlFinal.Host -ine 'www.dell.com') {
        throw 'A página de identificação por tag não terminou no endereço HTTPS esperado da Dell.'
    }
    $padraoToken = '^0-[A-Za-z0-9+/_=-]{16,}$'
    $segmento = [regex]::Match($UrlFinal.AbsolutePath, '(?i)/servicetag/(?<tag>[^/]+)(?:/|$)')
    if ($segmento.Success) {
        $valor = [Uri]::UnescapeDataString($segmento.Groups['tag'].Value)
        if ($valor -cmatch $padraoToken) { return $valor }
    }
    $texto = [Net.WebUtility]::HtmlDecode($Html).Replace('\"', '"').Replace('\/', '/')
    $padrao = '(?i)["'']?(?:EncryptedServiceTag|ServiceTag)["'']?\s*[:=]\s*["''](?<token>0-[A-Za-z0-9%+/_=-]{16,})["'']'
    $valores = @([regex]::Matches($texto, $padrao) | ForEach-Object { [Uri]::UnescapeDataString($_.Groups['token'].Value) } |
        Where-Object { $_ -cmatch $padraoToken } | Sort-Object -CaseSensitive -Unique)
    if ($valores.Count -ne 1) { throw 'A página Dell não forneceu um identificador inequívoco para a Service Tag. Consulta por tag não validada.' }
    return $valores[0]
}

function Get-DellTagContext {
    param([string]$ServiceTag, $Sessao)
    if ([string]::IsNullOrWhiteSpace($ServiceTag)) { throw 'Service Tag ausente no BIOS. Não foi realizada consulta por modelo como substituição.' }
    $tag = $ServiceTag.Trim().ToUpperInvariant()
    if ($tag -notmatch '^[A-Z0-9]{5,7}$') { throw 'Service Tag ausente ou inválida no BIOS. Não foi realizada consulta por modelo como substituição.' }
    $url = 'https://www.dell.com/support/product-details/pt-br/servicetag/{0}/drivers' -f [Uri]::EscapeDataString($tag)
    Write-Log 'Obtendo na página Dell o identificador da Service Tag para a consulta de downloads.'
    try {
        $pagina = Invoke-WebRequest -Uri $url -WebSession $Sessao -UseBasicParsing -TimeoutSec 120 -Headers @{ 'X-Requested-With' = 'XMLHttpRequest'; 'X-Robots-Tag' = 'noindex' } -ErrorAction Stop
    }
    catch {
        $respostaErro = Get-ObjectValue $_.Exception 'Response'
        $statusHttp = [int](Get-ObjectValue $respostaErro 'StatusCode')
        if ($statusHttp -eq 403) {
            throw 'HTTP 403: a Dell recusou o acesso à página por Service Tag. A verificação de pendências não foi realizada. Alternativa explícita: .\Gerar-RelatorioDell.ps1 -ConsultaSite Modelo (consulta ampla por modelo, também sujeita a bloqueio). Não houve troca automática de fonte.'
        }
        throw "Não foi possível identificar a Service Tag na Dell. Verifique a conexão e o acesso ao site; a consulta por tag é experimental. Não houve fallback por modelo. $($_.Exception.Message)"
    }
    return Get-DellTagToken -Html ([string]$pagina.Content) -UrlFinal $pagina.BaseResponse.ResponseUri
}

function Get-DellSiteDownloads {
    param([string]$Produto, [string]$SO, [string]$Pasta, [string]$ServiceTag, [ValidateSet('ServiceTag', 'Modelo')][string]$Consulta = 'Modelo')
    $sessao = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $token = $null
    if ($Consulta -eq 'ServiceTag') {
        $token = Get-DellTagContext -ServiceTag $ServiceTag -Sessao $sessao
        $url = 'https://www.dell.com/support/driver/pt-br/dep/api/driverlist/packdriversbytag?productcode={0}&servicetag={1}&oscode={2}&lob=PowerEdge&initialload=true' -f [Uri]::EscapeDataString($Produto), [Uri]::EscapeDataString($token), [Uri]::EscapeDataString($SO)
        Write-Log "Consultando os downloads por Service Tag: produto=$Produto; SO=$SO."
    }
    else {
        $url = 'https://www.dell.com/support/driver/pt-br/dep/api/driverlist/packdriversbyproduct?productcode={0}&oscode={1}&lob=PowerEdge&initialload=true' -f [Uri]::EscapeDataString($Produto), [Uri]::EscapeDataString($SO)
        Write-Log "Consultando os downloads por modelo e sistema operacional: produto=$Produto; SO=$SO."
    }
    try {
        $resposta = Invoke-WebRequest -Uri $url -WebSession $sessao -UseBasicParsing -TimeoutSec 120 -Headers @{ 'X-Requested-With' = 'XMLHttpRequest'; 'X-Robots-Tag' = 'noindex' } -ErrorAction Stop
    }
    catch {
        $respostaErro = Get-ObjectValue $_.Exception 'Response'
        $statusHttp = [int](Get-ObjectValue $respostaErro 'StatusCode')
        if ($statusHttp -eq 403) {
            throw "HTTP 403: a API interna da Dell recusou a consulta $Consulta. A verificação de pendências não foi realizada. Nenhuma outra fonte foi consultada."
        }
        throw "Falha ao consultar o site Dell. Verifique internet, proxy e acesso HTTPS. Nenhuma conclusão de ausência de atualizações foi feita. $($_.Exception.Message)"
    }
    # Preserva a resposta completa antes de filtrar: a API por tag também pode
    # trazer registros do modelo com IsTagDriver=0, conforme o JS da própria Dell.
    $bruta = ConvertFrom-DellSiteResponse -Texto ([string]$resposta.Content) -Produto $Produto
    $json = ConvertTo-Json -InputObject $bruta -Depth 30
    [IO.File]::WriteAllText((Join-Path $Pasta 'downloads-site-resposta.json'), $json, (New-Object Text.UTF8Encoding($true)))
    $raiz = if ($Consulta -eq 'ServiceTag') {
        ConvertFrom-DellSiteResponse -Texto $json -Produto $Produto -ExigirTag -ServiceTag $ServiceTag -TokenTag $token
    } else { $bruta }
    $json = ConvertTo-Json -InputObject $raiz -Depth 30
    [IO.File]::WriteAllText((Join-Path $Pasta 'downloads-site.json'), $json, (New-Object Text.UTF8Encoding($true)))
    @("Consulta=$Consulta", "URL=$url", "ColetadoEm=$((Get-Date).ToString('o'))", "SO=$SO", "Produto=$Produto", "RegistrosRecebidos=$(@($bruta.DriverListData).Count)", "RegistrosUsados=$(@($raiz.DriverListData).Count)") |
        Set-Content -LiteralPath (Join-Path $Pasta 'fonte-site.txt') -Encoding UTF8
    Write-Log "Site Dell: $(@($raiz.DriverListData).Count) downloads na consulta $Consulta. Essa contagem ainda não é a quantidade de pendências."
    return $raiz
}

function Assert-DellInputParameters {
    param([string]$Fonte, [string]$ArquivoSiteDell, [string]$ArquivoInventario, [bool]$CatalogoInformado)
    if ($ArquivoSiteDell -and ($Fonte -ne 'Site' -or $CatalogoInformado)) {
        throw '-ArquivoSiteDell é suportado apenas com -Fonte Site e não pode ser combinado com -Catalogo.'
    }
    if ($Fonte -eq 'Catalogo' -and $ArquivoInventario) { throw '-ArquivoInventario é suportado apenas com -Fonte Site.' }
}

function Get-DellHarRequestContext {
    param($Requisicao)
    # Apenas identifica a requisição. Nenhum endereço do HAR é acessado.
    $uri = $null
    if (-not [Uri]::TryCreate([string](Get-ObjectValue $Requisicao 'url'), [UriKind]::Absolute, [ref]$uri)) { return $null }
    if ($uri.Scheme -ne 'https' -or $uri.Host -ine 'www.dell.com' -or -not $uri.IsDefaultPort -or $uri.UserInfo -or $uri.Fragment) { return $null }
    if ($uri.AbsolutePath -notmatch '^/support/driver/[a-z]{2}-[a-z]{2}/dep/api/driverlist/packdriversby(?<escopo>product|tag)/?$') { return $null }
    $tipo = if ($Matches['escopo'] -ieq 'tag') { 'ServiceTag' } else { 'Modelo' }
    if ([string](Get-ObjectValue $Requisicao 'method') -ine 'GET') { throw 'A captura contém uma chamada de downloads com método não reconhecido. Exporte uma nova captura conforme a documentação.' }
    $parametros = @{}
    foreach ($parte in $uri.Query.TrimStart('?').Split('&')) {
        if (-not $parte) { continue }
        $par = $parte -split '=', 2
        $nome = [Uri]::UnescapeDataString($par[0].Replace('+', ' ')).ToLowerInvariant()
        $valor = if ($par.Count -eq 2) { [Uri]::UnescapeDataString($par[1].Replace('+', ' ')) } else { '' }
        if ($parametros.ContainsKey($nome)) { throw 'Parâmetros duplicados na requisição Dell do HAR. Faça uma captura limpa de apenas um servidor.' }
        $parametros[$nome] = $valor
    }
    foreach ($campo in @('productcode', 'oscode', 'lob')) {
        if (-not $parametros.ContainsKey($campo) -or [string]::IsNullOrWhiteSpace($parametros[$campo])) { throw "A requisição do HAR não informa '$campo'. Capture novamente a lista de downloads." }
    }
    $token = if ($parametros.ContainsKey('servicetag')) { [string]$parametros['servicetag'] } else { '' }
    if ($tipo -eq 'ServiceTag' -and -not $token) { throw 'Requisição por tag sem identificador no HAR.' }
    return [pscustomobject]@{
        Produto = $parametros['productcode']; SO = $parametros['oscode']; Familia = $parametros['lob']
        Tipo = $tipo; Token = $token; Endpoint = $uri.GetLeftPart([UriPartial]::Path)
    }
}

function ConvertTo-DellHarReference {
    param($Raiz)
    # Copia somente os campos usados na comparação. Não propaga cookies,
    # cabeçalhos, HTML, outros acessos nem identificadores da consulta por tag.
    $downloads = foreach ($item in @($Raiz.DriverListData)) {
        $formatos = foreach ($formato in @((Get-ObjectValue $item 'OthFileFrmts'))) {
            if ($null -ne $formato) { [pscustomobject]@{ FileName = [string](Get-ObjectValue $formato 'FileName'); FileType = [string](Get-ObjectValue $formato 'FileType') } }
        }
        $principal = Get-ObjectValue $item 'FileFrmtInfo'
        [pscustomobject][ordered]@{
            DriverId = [string]$item.DriverId; DriverName = [string]$item.DriverName; Type = [string]$item.Type
            DellVer = [string]$item.DellVer; Imp = [string](Get-ObjectValue $item 'Imp')
            ReleaseDate = [string]$item.ReleaseDate; CatName = [string](Get-ObjectValue $item 'CatName')
            FileFrmtInfo = if ($null -ne $principal) { [pscustomobject]@{ FileName = [string](Get-ObjectValue $principal 'FileName'); FileType = [string](Get-ObjectValue $principal 'FileType') } } else { $null }
            OthFileFrmts = @($formatos)
        }
    }
    return [pscustomobject][ordered]@{ ProductCode = [string]$Raiz.ProductCode; DriverListData = @($downloads) }
}

function Import-DellSiteHar {
    param([string]$Arquivo, [string]$Produto, [string]$SO, [string]$Pasta, [string]$ServiceTag,
        [ValidateSet('Modelo', 'ServiceTag')][string]$Consulta = 'Modelo')
    if (-not (Test-Path -LiteralPath $Arquivo -PathType Leaf)) { throw 'Arquivo HAR não encontrado. Informe -ArquivoSiteDell com o caminho do arquivo exportado.' }
    $info = Get-Item -LiteralPath $Arquivo
    if ($info.Extension -ine '.har') { throw 'ArquivoSiteDell deve ser um arquivo .har exportado pela guia Rede do navegador, não HTML, PDF ou CSV.' }
    # Lê e calcula o hash do mesmo arquivo, impedindo alterações durante a leitura.
    $stream = [IO.File]::Open($info.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $leitor = $null; $sha = [Security.Cryptography.SHA256]::Create()
    try {
        if ($stream.Length -eq 0 -or $stream.Length -gt 100MB) { throw 'HAR vazio ou maior que 100 MiB. Limpe a guia Rede e capture somente a página Dell do servidor.' }
        $leitor = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true, 4096, $true)
        $texto = $leitor.ReadToEnd()
        $stream.Position = 0
        $hash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '')
    }
    finally { if ($leitor) { $leitor.Dispose() }; $stream.Dispose(); $sha.Dispose() }
    try { $har = ConvertFrom-Json -InputObject $texto -ErrorAction Stop }
    catch { throw 'HAR inválido ou truncado. Exporte novamente a captura pelo navegador.' }
    $entradas = Get-ObjectValue (Get-ObjectValue $har 'log') 'entries'
    if ($null -eq $entradas -or @($entradas).Count -eq 0) { throw 'O arquivo não contém requisições HAR. Abra F12 > Rede antes de carregar os downloads e exporte com conteúdo.' }
    $selecionada = $null; $indice = -1; $quantidade = 0
    foreach ($entrada in @($entradas)) {
        $indice++
        $contexto = Get-DellHarRequestContext (Get-ObjectValue $entrada 'request')
        if ($null -eq $contexto) { continue }
        if ($contexto.Produto -ine $Produto -or $contexto.SO -ine $SO -or $contexto.Familia -ine 'PowerEdge') { continue }
        $resposta = Get-ObjectValue $entrada 'response'
        if ([int](Get-ObjectValue $resposta 'status') -ne 200) { throw 'Uma consulta de downloads deste modelo/SO falhou no HAR. Limpe a guia Rede e salve uma captura com resposta HTTP 200.' }
        $conteudo = Get-ObjectValue $resposta 'content'
        $corpo = [string](Get-ObjectValue $conteudo 'text')
        if ([string]::IsNullOrWhiteSpace($corpo)) { throw 'O HAR não contém o corpo da resposta de downloads. Desative o cache, recarregue a página e exporte HAR com conteúdo.' }
        $codificacao = [string](Get-ObjectValue $conteudo 'encoding')
        if ($codificacao -eq 'base64') {
            try { $corpo = (New-Object Text.UTF8Encoding($false, $true)).GetString([Convert]::FromBase64String($corpo)) }
            catch { throw 'Corpo base64 inválido na resposta de downloads do HAR.' }
        }
        elseif ($codificacao) { throw 'Codificação do corpo HAR não reconhecida. Exporte novamente pelo Edge ou Chrome.' }
        $instante = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse([string](Get-ObjectValue $entrada 'startedDateTime'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$instante)) {
            throw 'A resposta no HAR não informa uma data de captura válida.'
        }
        # Não escolhe arbitrariamente entre capturas de tags/respostas diferentes.
        if ($selecionada -and ($selecionada.Contexto.Tipo -cne $contexto.Tipo -or $selecionada.Contexto.Token -cne $contexto.Token -or $selecionada.Corpo -cne $corpo)) {
            throw 'O HAR contém respostas diferentes para este modelo/SO. Limpe a guia Rede e capture apenas uma consulta; nenhuma lista foi escolhida arbitrariamente.'
        }
        $quantidade++
        if ($null -eq $selecionada -or $instante -ge $selecionada.Instante) {
            $selecionada = [pscustomobject]@{ Contexto = $contexto; Corpo = $corpo; Instante = $instante; Indice = $indice }
        }
    }
    if ($null -eq $selecionada) { throw "Nenhuma resposta Dell de downloads para produto=$Produto e SO=$SO foi encontrada no HAR. Escolha no site o Windows instalado neste servidor e capture novamente." }
    $raiz = ConvertFrom-DellSiteResponse -Texto $selecionada.Corpo -Produto $Produto
    if ((Get-ObjectValue $raiz 'IsNoDriversFound') -eq $true) { throw 'A captura Dell indica ausência de dados de downloads. Verificação inconclusiva.' }
    $recebidos = @($raiz.DriverListData).Count
    $bruta = ConvertTo-DellHarReference $raiz
    if ($Consulta -eq 'ServiceTag') {
        # O token opaco da URL só liga request/response. Não comprova o BIOS local.
        $tagRetornada = [string](Get-ObjectValue $raiz 'ServiceTag')
        if ($selecionada.Contexto.Tipo -ne 'ServiceTag' -or [string]::IsNullOrWhiteSpace($ServiceTag) -or $tagRetornada -ine $ServiceTag.Trim()) {
            throw 'O HAR não comprova a Service Tag local em texto claro. Para usar a lista ampla do modelo, execute sem -ConsultaSite ServiceTag; para filtrar pela tag é necessária uma captura que confirme sua identidade.'
        }
        $raiz = ConvertFrom-DellSiteResponse -Texto $selecionada.Corpo -Produto $Produto -ExigirTag -ServiceTag $ServiceTag
    }
    else {
        Write-Log 'Importação manual: usando a lista ampla do modelo/SO. A página aberta por tag não comprova filtro pela tag; o inventário local continua necessário.' 'AVISO'
    }
    foreach ($pacote in @($raiz.DriverListData)) {
        if ($pacote.Type -in @('BIOS', 'FRMW', 'DRVR')) {
            if (-not (ConvertTo-CriticalityLabel ([string](Get-ObjectValue $pacote 'Imp')))) { throw 'A resposta HAR não informa uma criticidade reconhecida para um download Dell. Verificação inconclusiva.' }
            if ([string]::IsNullOrWhiteSpace([string](Get-ObjectValue $pacote 'CatName'))) { throw 'A resposta HAR não informa a categoria de um download Dell.' }
            if ((Get-SiteReleaseDate $pacote) -eq [datetime]::MinValue) { throw 'Data de lançamento não reconhecida em um download do HAR.' }
        }
    }
    $usada = ConvertTo-DellHarReference $raiz
    # Só persiste as referências normalizadas necessárias, nunca o HAR inteiro.
    foreach ($saida in @(@('downloads-site-resposta.json', $bruta), @('downloads-site.json', $usada))) {
        [IO.File]::WriteAllText((Join-Path $Pasta $saida[0]), (ConvertTo-Json -InputObject $saida[1] -Depth 15), (New-Object Text.UTF8Encoding($true)))
    }
    @('Fonte=ArquivoHAR', "Consulta=$Consulta", "OrigemConsulta=$($selecionada.Contexto.Tipo)", "Arquivo=$($info.FullName)", "SHA256=$hash",
        "CapturadoEm=$($selecionada.Instante.ToString('o'))", "ImportadoEm=$((Get-Date).ToString('o'))", "EntradaHAR=$($selecionada.Indice)",
        "Endpoint=$($selecionada.Contexto.Endpoint)", "Produto=$Produto", "SO=$SO", "RegistrosRecebidos=$recebidos", "RegistrosUsados=$(@($usada.DriverListData).Count)", "RespostasIdenticas=$quantidade") |
        Set-Content -LiteralPath (Join-Path $Pasta 'fonte-site.txt') -Encoding UTF8
    Write-Log "HAR importado: produto=$Produto; SO=$SO; seleção=$Consulta; capturado em $($selecionada.Instante.ToString('o')); $(@($usada.DriverListData).Count) downloads."
    return $usada
}

function Get-DellSiteReference {
    param([string]$ArquivoSiteDell, [string]$Produto, [string]$SO, [string]$Pasta, [string]$ServiceTag,
        [ValidateSet('Modelo', 'ServiceTag')][string]$Consulta = 'Modelo')
    if ($ArquivoSiteDell) { return Import-DellSiteHar -Arquivo $ArquivoSiteDell -Produto $Produto -SO $SO -Pasta $Pasta -ServiceTag $ServiceTag -Consulta $Consulta }
    return Get-DellSiteDownloads -Produto $Produto -SO $SO -Pasta $Pasta -ServiceTag $ServiceTag -Consulta $Consulta
}

function Get-ValidatedInventory {
    param([string]$Texto, [switch]$ExigirEncerramento)
    $linhas = @(Get-DsuTextLines $Texto)
    if (($linhas -join "`n") -match '(?im)^\s*(?:ERROR\b|FATAL\b|Failed\b|Unable\b|Could\s+not\b)') {
        throw 'O inventário contém mensagem de falha. Não é possível considerar a coleta concluída com sucesso.'
    }
    if ($ExigirEncerramento -and $Texto -notmatch '(?im)^\s*Exiting DSU!\s*$') {
        throw 'O arquivo de inventário não contém Exiting DSU!. Aguarde a conclusão do DSU antes de reutilizá-lo.'
    }
    $lista = @(ConvertFrom-DsuInventoryText $Texto)
    $esperados = @($linhas | Where-Object { $_ -match '^\d+[.)]\s+' }).Count
    if ($lista.Count -eq 0 -or $lista.Count -ne $esperados) {
        throw "Inventário vazio ou com linhas não reconhecidas: $esperados linhas numeradas; $($lista.Count) interpretadas. Ajuste o parser antes de concluir o relatório."
    }
    return $lista
}

function Read-SharedText {
    param([string]$Arquivo)
    # Permite reutilizar o texto já escrito mesmo se a janela antiga ainda mantém
    # o arquivo aberto. Get-ValidatedInventory exige a mensagem de encerramento.
    $stream = [IO.File]::Open($Arquivo, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $leitor = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true)
    try { return $leitor.ReadToEnd() } finally { $leitor.Dispose(); $stream.Dispose() }
}

function ConvertFrom-DsuInventoryXml {
    param([string]$Texto)
    # SVMInventory observado no coletor Dell. Não resolve DTDs ou entidades externas.
    $config = New-Object Xml.XmlReaderSettings
    $config.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $config.XmlResolver = $null
    $config.MaxCharactersInDocument = 10MB
    $origem = New-Object IO.StringReader($Texto)
    $leitor = [Xml.XmlReader]::Create($origem, $config)
    try {
        $xml = New-Object Xml.XmlDocument
        $xml.XmlResolver = $null
        $xml.Load($leitor)
    }
    finally { $leitor.Dispose(); $origem.Dispose() }
    $raiz = $xml.DocumentElement
    if ($null -eq $raiz -or $raiz.Name -cne 'SVMInventory' -or $raiz.NamespaceURI -or $raiz.GetAttribute('schemaVersion') -ne '1.0') {
        throw 'XML de inventário não reconhecido. Esperado SVMInventory schemaVersion=1.0; não use um catálogo ou relatório JSON.'
    }
    $dispositivos = @($raiz.SelectNodes('Device'))
    if ($dispositivos.Count -eq 0) { throw 'XML de inventário sem dispositivos. A coleta não pode ser considerada concluída.' }
    foreach ($dispositivo in $dispositivos) {
        $aplicacoes = @($dispositivo.SelectNodes('Application'))
        if ($aplicacoes.Count -eq 0) { throw 'XML de inventário contém dispositivo sem Application; coleta incompleta ou schema diferente.' }
        foreach ($aplicacao in $aplicacoes) {
            foreach ($atributo in @('display', 'version', 'componentType')) {
                if ([string]::IsNullOrWhiteSpace($aplicacao.GetAttribute($atributo))) { throw "XML de inventário contém Application sem $atributo." }
            }
            # Preserva cada instância, inclusive discos iguais em baias diferentes.
            [pscustomobject]@{
                Nome = $aplicacao.GetAttribute('display').Trim()
                Tipo = $aplicacao.GetAttribute('componentType').Trim()
                Versao = $aplicacao.GetAttribute('version').Trim()
                ModeloDispositivo = $dispositivo.GetAttribute('display').Trim()
                ComponentID = $dispositivo.GetAttribute('componentID').Trim()
                FQDD = $dispositivo.GetAttribute('FQDD').Trim()
                VendorID = $dispositivo.GetAttribute('vendorID').Trim()
                DeviceID = $dispositivo.GetAttribute('deviceID').Trim()
                SubVendorID = $dispositivo.GetAttribute('subVendorID').Trim()
                SubDeviceID = $dispositivo.GetAttribute('subDeviceID').Trim()
                Bus = $dispositivo.GetAttribute('bus').Trim()
                Device = $dispositivo.GetAttribute('device').Trim()
                Function = $dispositivo.GetAttribute('function').Trim()
                Enumerador = $dispositivo.GetAttribute('enum').Trim()
            }
        }
    }
}

function Import-DsuInventory {
    param([string]$Arquivo, [string]$Pasta)
    # Obtém uma cópia estável; StreamReader reconhece BOM UTF-16 do XML Dell.
    $stream = [IO.File]::Open($Arquivo, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -gt 10MB) { throw 'Inventário excede o limite de 10 MiB.' }
        $leitor = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true)
        try { $texto = $leitor.ReadToEnd() } finally { $leitor.Dispose() }
    }
    finally { $stream.Dispose() }
    $ehXml = ([IO.Path]::GetExtension($Arquivo) -ieq '.xml' -or $texto.TrimStart().StartsWith('<'))
    if ($ehXml) { $lista = @(ConvertFrom-DsuInventoryXml -Texto $texto); $extensao = 'xml' }
    else { $lista = @(Get-ValidatedInventory -Texto $texto -ExigirEncerramento); $extensao = 'txt' }
    if ($Pasta) {
        # Salva um snapshot com declaração coerente; nunca altera o arquivo recebido.
        $snapshot = $texto
        if ($ehXml) { $snapshot = $snapshot -replace '(?i)encoding\s*=\s*["'']UTF-16["'']', 'encoding="UTF-8"' }
        [IO.File]::WriteAllText((Join-Path $Pasta "inventory.importado.$extensao"), $snapshot, (New-Object Text.UTF8Encoding($true)))
    }
    Write-Log "Inventário $extensao validado: $($lista.Count) componentes."
    return $lista
}

function Get-SiteInventoryArguments {
    param([string]$Ajuda, [string]$ArquivoXml)
    if ($Ajuda -notmatch '(?im)(?<![\w-])--inventory(?=[\s=,\[\]<>;:]|$)') { throw 'A ajuda do DSU não confirmou --inventory. Consulte help.stdout.txt.' }
    if ($Ajuda -match '(?im)(?<![\w-])--output-inventory-xml(?=[\s=,\[\]<>;:]|$)') {
        return @('--inventory', ('--output-inventory-xml=' + $ArquivoXml))
    }
    Write-Log 'Esta versão do DSU não anuncia --output-inventory-xml; usando texto, com menor identificação de hardware.' 'AVISO'
    return @('--inventory')
}

function Get-DellDiskRule {
    param($Instalado)
    # Regras locais restritas à identidade observada e ao pacote Dell verificado.
    # O coletor observado abrevia o modelo Seagate: CID e FQDD são exigidos.
    if ($Instalado.Tipo -ne 'FRMW' -or ([string](Get-ObjectValue $Instalado 'FQDD')) -notmatch '^Disk\.Bay\.\d+:') { return $null }
    $modeloDisco = [string](Get-ObjectValue $Instalado 'ModeloDispositivo')
    $cid = [string](Get-ObjectValue $Instalado 'ComponentID')
    if ($cid -eq '105266' -and $modeloDisco -eq 'MG04SCA20ENY') {
        return [pscustomobject]@{ DriverId='RG9MK'; ModeloTitulo='MG04SCA20ENY'; VersaoAlvo='EG03'; Anteriores=@('EG02') }
    }
    if ($cid -eq '111175' -and $modeloDisco -in @('ST8000NM023B-2TJ', 'ST8000NM023B-2TJ133')) {
        return [pscustomobject]@{ DriverId='P183W'; ModeloTitulo='ST8000NM023B'; VersaoAlvo='LA0C'; Anteriores=@('LA0B') }
    }
    return $null
}

function Get-DsuSiteInventory {
    param([string]$Executavel, [string]$Ajuda, [string]$Pasta, [int]$LimiteMinutos)
    $arquivoXml = Join-Path $Pasta 'inventory.xml'
    $argumentos = @(Get-SiteInventoryArguments -Ajuda $Ajuda -ArquivoXml $arquivoXml)
    $bruto = Invoke-DsuReadOnly $Executavel $argumentos 'inventory' $LimiteMinutos
    if ($bruto.ExitCode -ne 0) { throw "Inventário DSU falhou (código $($bruto.ExitCode)). Consulte os arquivos brutos." }
    if ($argumentos.Count -gt 1) {
        # Se o DSU prometeu XML, ausência ou corrupção são erro, sem fallback.
        $lista = @(Import-DsuInventory -Arquivo $arquivoXml)
        if ($bruto.Text -match '(?im)^\s*(?:ERROR\b|FATAL\b|Failed\b|Unable\b|Could\s+not\b)') { throw 'DSU retornou mensagem de falha durante a coleta XML; consulte inventory.stdout.txt.' }
        return $lista
    }
    return Get-ValidatedInventory -Texto $bruto.Text
}

function Compare-DellDiskVersion {
    param($Regra, [string]$Instalada, [string]$Disponivel)
    # Não ordena firmware alfanumérico. Só reconhece pares explícitos da regra.
    if ($null -eq $Regra -or $Disponivel -cne $Regra.VersaoAlvo) { return $null }
    if ($Instalada -ceq $Regra.VersaoAlvo) { return 0 }
    if ($Instalada -cin $Regra.Anteriores) { return -1 }
    return $null
}

function Compare-DottedVersion {
    param([string]$Instalada, [string]$Disponivel)
    # Retorna null para versões alfanuméricas, zeros ou formatos não comparáveis.
    foreach ($valor in @($Instalada, $Disponivel)) {
        if ($valor -notmatch '^\d+(?:\.\d+){1,7}$' -or $valor -match '^0+(?:\.0+)*$') { return $null }
    }
    $a = @($Instalada -split '\.')
    $b = @($Disponivel -split '\.')
    for ($i = 0; $i -lt [Math]::Max($a.Count, $b.Count); $i++) {
        $va = [UInt64]0
        $vb = [UInt64]0
        if ($i -lt $a.Count -and -not [UInt64]::TryParse($a[$i], [ref]$va)) { return $null }
        if ($i -lt $b.Count -and -not [UInt64]::TryParse($b[$i], [ref]$vb)) { return $null }
        if ($va -lt $vb) { return -1 }
        if ($va -gt $vb) { return 1 }
    }
    return 0
}

function Get-BroadcomPciProfile {
    param($Dispositivo)
    # Tuplas completas confirmadas em SupportedDevices do DUP oficial DFF48/49X84.
    $ids = @('VendorID','DeviceID','SubVendorID','SubDeviceID') | ForEach-Object { ([string](Get-ObjectValue $Dispositivo $_)).ToUpperInvariant() }
    $chave = $ids -join ':'
    if ($chave -in @('14E4:165F:14E4:2003','14E4:165F:1028:0639')) { return $chave }
    return ''
}

function Get-DellWindowsNetworkDrivers {
    # Consulta local de drivers de hardware. Não consulta Windows Update ou patches.
    $drivers = @(Get-CimInstance -ClassName Win32_PnPSignedDriver -Filter "DeviceClass='NET'" -OperationTimeoutSec 30 -ErrorAction Stop)
    foreach ($driver in $drivers) {
        $id = [string](Get-ObjectValue $driver 'DeviceID')
        if ($id -notmatch '(?i)^PCI\\VEN_(?<vendor>[0-9A-F]{4})&DEV_(?<device>[0-9A-F]{4})&SUBSYS_(?<subdevice>[0-9A-F]{4})(?<subvendor>[0-9A-F]{4})(?:&|\\|$)') { continue }
        $registro = [pscustomobject]@{
            PnpDeviceID=$id; Nome=[string](Get-ObjectValue $driver 'DeviceName')
            VendorID=$Matches.vendor; DeviceID=$Matches.device
            SubVendorID=$Matches.subvendor; SubDeviceID=$Matches.subdevice
            Versao=[string](Get-ObjectValue $driver 'DriverVersion')
            Provedor=[string](Get-ObjectValue $driver 'DriverProviderName')
            InfName=[string](Get-ObjectValue $driver 'InfName')
            Assinado=(Get-ObjectValue $driver 'IsSigned')
        }
        # Só guarda os perfis Dell atualmente implementados, sem inventariar o SO.
        if (Get-BroadcomPciProfile $registro) { $registro }
    }
}

function Get-BroadcomInstalledDriver {
    param([object[]]$Inventario, [object[]]$DriversWindows)
    $falha = [pscustomobject]@{ Valido=$false; Versao=''; InfName=''; Quantidade=0; Motivo='DSU não fornece uma versão de driver utilizável; faltam dados CIM completos, assinados e com provedor Broadcom para todas as interfaces inventariadas.' }
    $interfaces = @($Inventario | Where-Object { $_.Tipo -eq 'FRMW' -and (Get-ObjectValue $_ 'VendorID') -eq '14E4' -and (Get-ObjectValue $_ 'DeviceID') -eq '165F' })
    if ($interfaces.Count -eq 0) { return $falha }
    if (@($interfaces | Where-Object { -not (Get-BroadcomPciProfile $_) }).Count) {
        $falha.Motivo = 'Há uma interface Broadcom sem perfil PCI validado; não é seguro atribuir uma versão à família inteira.'
        return $falha
    }
    $perfis = @($interfaces | ForEach-Object { Get-BroadcomPciProfile $_ } | Select-Object -Unique)
    $evidencias = @()
    foreach ($perfil in $perfis) {
        $esperadas = @($interfaces | Where-Object { (Get-BroadcomPciProfile $_) -eq $perfil }).Count
        $encontradas = @($DriversWindows | Where-Object { (Get-BroadcomPciProfile $_) -eq $perfil })
        if ($encontradas.Count -ne $esperadas) { return $falha }
        $evidencias += $encontradas
    }
    $ids = @($evidencias | ForEach-Object { [string](Get-ObjectValue $_ 'PnpDeviceID') } | Select-Object -Unique)
    if ($ids.Count -ne $interfaces.Count -or $ids -contains '') { return $falha }
    foreach ($item in $evidencias) {
        if ((Get-ObjectValue $item 'Assinado') -isnot [bool] -or (Get-ObjectValue $item 'Assinado') -ne $true -or ([string](Get-ObjectValue $item 'Provedor')) -notmatch '(?i)^Broadcom\b' -or
            $null -eq (Compare-DottedVersion ([string](Get-ObjectValue $item 'Versao')) '214.0.0.6')) { return $falha }
    }
    $versoes = @($evidencias | ForEach-Object { [string](Get-ObjectValue $_ 'Versao') } | Select-Object -Unique)
    if ($versoes.Count -ne 1) {
        $falha.Motivo = 'As interfaces Broadcom têm versões de driver diferentes. Consulte drivers-windows.json; não foi atribuída uma versão arbitrária à família.'
        return $falha
    }
    return [pscustomobject]@{ Valido=$true; Versao=$versoes[0]; InfName=(@($evidencias | ForEach-Object { Get-ObjectValue $_ 'InfName' } | Select-Object -Unique) -join ' | '); Quantidade=$interfaces.Count; Motivo='' }
}

function Get-SiteReleaseDate {
    param($Pacote)
    $data = [datetime]::MinValue
    if ([datetime]::TryParse([string](Get-ObjectValue $Pacote 'ReleaseDate'), [Globalization.CultureInfo]::GetCultureInfo('en-US'), [Globalization.DateTimeStyles]::None, [ref]$data)) { return $data }
    return [datetime]::MinValue
}

function Get-SiteWindowsPackage {
    param($Pacote)
    $arquivos = @()
    $principal = Get-ObjectValue $Pacote 'FileFrmtInfo'
    if ($null -ne $principal) { $arquivos += $principal }
    $outros = Get-ObjectValue $Pacote 'OthFileFrmts'
    if ($null -ne $outros) { $arquivos += @($outros) }
    $validos = @($arquivos | Where-Object {
        ([string](Get-ObjectValue $_ 'FileName')) -match '(?i)\.exe$' -and
        ([string](Get-ObjectValue $_ 'FileType')) -in @('LW64', 'LWXP')
    } | Sort-Object @{ Expression = { if ((Get-ObjectValue $_ 'FileType') -eq 'LW64') { 0 } else { 1 } } })
    if ($validos.Count) { return $validos[0] }
    return $null
}

function New-SiteAssessmentRows {
    param([object[]]$Inventario, [object[]]$Downloads, [string]$Hostname, [string]$ServiceTag, [string]$Modelo, [string]$SO, [object[]]$DriversWindows = @())
    foreach ($instalado in $Inventario) {
        if ($instalado.Tipo -in @('APAC', 'APP', 'EAPP')) { continue }
        $resultado = [pscustomobject][ordered]@{
            Hostname = $Hostname; ServiceTag = $ServiceTag; Modelo = $Modelo
            Componente = $instalado.Nome; Categoria = $instalado.Tipo; VersaoAtual = $instalado.Versao
            VersaoNova = ''; Criticidade = ''; DataDeLancamento = ''; NomeDoPacote = ''
            Status = 'Inconclusivo'; Motivo = ''; URL = ''
            FonteVersao = 'Inventário DSU'; VersaoDSU = $instalado.Versao
            InfName = ''; QuantidadeDispositivosDriver = ''
        }
        # Só o CSV de verificação recebe estes campos; o principal mantém 10 colunas.
        foreach ($campo in @('ModeloDispositivo','ComponentID','FQDD','VendorID','DeviceID','SubVendorID','SubDeviceID','Bus','Device','Function','Enumerador')) {
            $resultado | Add-Member -NotePropertyName $campo -NotePropertyValue ([string](Get-ObjectValue $instalado $campo))
        }
        $regraDisco = Get-DellDiskRule -Instalado $instalado
        $perfilBroadcom = Get-BroadcomPciProfile -Dispositivo $instalado
        $modoBroadcom = ''
        $candidatos = @()
        if ($instalado.Tipo -notin @('BIOS', 'FRMW', 'DRVR')) {
            $resultado.Motivo = 'Tipo de componente ausente ou desconhecido no inventário; registro preservado para revisão.'
            $resultado
            continue
        }
        # Regras deliberadamente específicas: o título genérico de uma NIC/disco
        # e a versão do pacote não comprovam a versão do firmware de cada dispositivo.
        if ($instalado.Tipo -eq 'BIOS') {
            $candidatos = @($Downloads | Where-Object { $_.Type -eq 'BIOS' })
        }
        elseif ($instalado.Tipo -eq 'FRMW' -and $instalado.Nome -match '(?i)^(?:Integrated Dell Remote Access Controller|iDRAC\b)') {
            $candidatos = @($Downloads | Where-Object { $_.Type -eq 'FRMW' -and $_.DriverName -match '(?i)^iDRAC\b' })
        }
        elseif ($instalado.Tipo -eq 'FRMW' -and $instalado.Nome -match '(?i)^(?:Dell\s+)?PERC\s+(?<modelo>H\d{3,4}[A-Za-z]*|S\d{3,4})\b') {
            $controladora = [regex]::Escape($Matches['modelo'])
            $padrao = '(?i)(?<![A-Za-z0-9])' + $controladora + '(?![A-Za-z0-9])'
            $candidatos = @($Downloads | Where-Object { $_.Type -eq 'FRMW' -and $_.DriverName -match '(?i)\bPERC\b' -and $_.DriverName -match $padrao })
        }
        elseif ($instalado.Tipo -eq 'FRMW' -and $instalado.Nome -match '(?i)^System CPLD$') {
            $candidatos = @($Downloads | Where-Object { $_.Type -eq 'FRMW' -and $_.DriverName -match '(?i)\bCPLD\b' })
        }
        elseif ($null -ne $regraDisco) {
            $modeloTitulo = '(?i)(?<![A-Za-z0-9])' + [regex]::Escape($regraDisco.ModeloTitulo) + '(?![A-Za-z0-9])'
            $candidatos = @($Downloads | Where-Object { $_.Type -eq 'FRMW' -and $_.DriverId -eq $regraDisco.DriverId -and $_.DriverName -match $modeloTitulo })
        }
        elseif ($instalado.Tipo -eq 'FRMW' -and $perfilBroadcom) {
            $modoBroadcom = 'Firmware'
            $candidatos = @($Downloads | Where-Object { $_.Type -eq 'FRMW' -and $_.DriverId -eq 'DFF48' -and $_.DriverName -match '(?i)Broadcom.*NetXtreme(?!-E)' })
        }
        elseif ($instalado.Tipo -eq 'DRVR' -and (Get-ObjectValue $instalado 'ComponentID') -eq '8641' -and $instalado.Nome -eq 'Broadcom NetXtreme Driver Family') {
            $modoBroadcom = 'Driver'
            $driverWindows = Get-BroadcomInstalledDriver -Inventario $Inventario -DriversWindows $DriversWindows
            if (-not $driverWindows.Valido) {
                $resultado.Motivo = $driverWindows.Motivo
                $resultado
                continue
            }
            $resultado.VersaoAtual = $driverWindows.Versao
            $resultado.FonteVersao = 'CIM Win32_PnPSignedDriver; versão NDIS'
            $resultado.InfName = $driverWindows.InfName
            $resultado.QuantidadeDispositivosDriver = [string]$driverWindows.Quantidade
            $candidatos = @($Downloads | Where-Object { $_.Type -eq 'DRVR' -and $_.DriverId -eq '49X84' -and $_.DriverName -match '(?i)Broadcom' -and $_.DriverName -match '(?i)NetXtreme(?!-E)' })
        }
        else {
            $resultado.Motivo = 'Não há regra validada para associar a identidade deste dispositivo e sua versão ao pacote Dell. Consulte os identificadores no CSV de verificação; ausência de regra não significa ausência de atualização.'
            if ($instalado.Versao -match '^0+(?:\.0+)*$') { $resultado.Motivo = 'DSU informou versão zero; não é uma versão instalada válida para comparação.' }
            $resultado
            continue
        }
        # Exige DUP Windows. Não toma um PDF, assinatura ou pacote Linux como update.
        $candidatos = @($candidatos | Where-Object { $null -ne (Get-SiteWindowsPackage $_) })
        if ($candidatos.Count -eq 0) {
            $resultado.Motivo = 'Não foi encontrado um pacote Windows com associação confirmada a este componente. Ausência na lista não comprova que está atualizado.'
            $resultado
            continue
        }
        $ordenados = @($candidatos | Sort-Object @{ Expression = { Get-SiteReleaseDate $_ }; Descending = $true })
        $ultimaData = Get-SiteReleaseDate $ordenados[0]
        $mesmaData = @($ordenados | Where-Object { (Get-SiteReleaseDate $_) -eq $ultimaData })
        $versoes = @($mesmaData | ForEach-Object { ([string]$_.DellVer -split ',')[0].Trim() } | Select-Object -Unique)
        if ($ultimaData -eq [datetime]::MinValue -or $versoes.Count -ne 1) {
            $resultado.Motivo = 'Datas inválidas ou mais de uma versão candidata na mesma data. Associação ambígua.'
            $resultado
            continue
        }
        $pacote = $mesmaData[0]
        $arquivo = Get-SiteWindowsPackage $pacote
        $nova = ([string]$pacote.DellVer -split ',')[0].Trim()
        if ($modoBroadcom -eq 'Firmware') {
            if ((Compare-DottedVersion $nova '22.00.6') -ne 0 -or $nova -notmatch '^22\.0{1,2}\.6$' -or $resultado.VersaoAtual -notmatch '^\d{2}\.\d{1,2}\.\d{1,3}$') {
                $resultado.Motivo = 'Perfil PCI associado ao DFF48, mas a versão não corresponde ao formato FFV validado ou à referência 22.00.6.'
                $resultado
                continue
            }
        }
        if ($modoBroadcom -eq 'Driver') {
            # A versão de família 21.80.3 NÃO é a versão do driver NDIS 214.0.0.6.
            # Mapeamento confirmado nas notas oficiais do pacote 49X84.
            if ($nova -cne '21.80.3' -or $SO -notin @('WST14','WS19L')) {
                $resultado.Motivo = 'Pacote/Windows fora do mapeamento NDIS validado para 49X84; associação inconclusiva.'
                $resultado
                continue
            }
            $nova = '214.0.0.6'
        }
        $resultado.VersaoNova = $nova
        $resultado.Categoria = [string](Get-ObjectValue $pacote 'CatName')
        $resultado.Criticidade = ConvertTo-CriticalityLabel ([string](Get-ObjectValue $pacote 'Imp'))
        if (-not $resultado.Criticidade) { $resultado.Criticidade = 'Não informada' }
        $resultado.DataDeLancamento = $ultimaData.ToString('yyyy-MM-dd')
        $resultado.NomeDoPacote = [string](Get-ObjectValue $arquivo 'FileName')
        $resultado.URL = 'https://www.dell.com/support/home/pt-br/drivers/driversdetails?driverid=' + $pacote.DriverId
        if ($null -ne $regraDisco) { $comparacao = Compare-DellDiskVersion -Regra $regraDisco -Instalada $instalado.Versao -Disponivel $nova }
        else { $comparacao = Compare-DottedVersion -Instalada $resultado.VersaoAtual -Disponivel $nova }
        if ($null -eq $comparacao) { $resultado.Motivo = 'Versões alfanuméricas, zero ou formatos não comparáveis automaticamente.' }
        elseif ($comparacao -lt 0) { $resultado.Status = 'Pendente'; $resultado.Motivo = 'Componente identificado; versão instalada inferior à versão publicada na referência consultada.' }
        elseif ($comparacao -eq 0) { $resultado.Status = 'Atualizado na referência'; $resultado.Motivo = 'A versão instalada coincide com a versão publicada na referência consultada.' }
        else { $resultado.Status = 'Acima da referência'; $resultado.Motivo = 'A versão instalada é superior à referência consultada; não sugerir downgrade.' }
        if ($null -ne $regraDisco) {
            if ($null -eq $comparacao) { $resultado.Motivo = 'Disco associado, mas o par de versões não consta na regra validada; não é usada ordem alfabética para firmware.' }
            else { $resultado.Motivo += ' Regra local por modelo, ComponentID, FQDD, DriverId e par de versões explícito; validar aplicabilidade e pré-requisitos do DUP antes de instalar.' }
        }
        if ($modoBroadcom -eq 'Firmware') {
            $resultado.Motivo += ' Associação pelos quatro PCI IDs do package.xml do DFF48; comparação da Family Firmware Version, sem executar DUP. Validar combinação de firmware/driver antes de instalar.'
            if ($SO -eq 'WST14') { $resultado.Motivo += ' Windows Server 2016 não consta nos SOs listados para DFF48; a pendência de firmware não autoriza executar esse DUP no Windows 2016. Validar método de atualização fora do SO com a Dell.' }
        }
        if ($modoBroadcom -eq 'Driver') { $resultado.Motivo += ' Comparação NDIS para todas as interfaces do perfil; 49X84: família 21.80.3, driver NDIS 214.0.0.6. Não são atualizações do Windows.' }
        $resultado
    }
}

function Export-SiteAssessment {
    param([object[]]$Verificacoes, [string]$Arquivo, [string]$Hostname, [string]$ServiceTag, [string]$Modelo)
    if ($Verificacoes.Count -eq 0) { throw 'O inventário não contém BIOS, firmware ou drivers reconhecidos. Verificação inconclusiva.' }
    $colunas = @('Hostname', 'ServiceTag', 'Modelo', 'Componente', 'Categoria', 'VersaoAtual', 'VersaoNova', 'Criticidade', 'DataDeLancamento', 'NomeDoPacote')
    $pendentes = @($Verificacoes | Where-Object { $_.Status -eq 'Pendente' })
    $inconclusivos = @($Verificacoes | Where-Object { $_.Status -eq 'Inconclusivo' })
    $linhas = @($pendentes | Select-Object -Property $colunas)
    if ($inconclusivos.Count) {
        $linhas += [pscustomobject][ordered]@{
            Hostname = $Hostname; ServiceTag = $ServiceTag; Modelo = $Modelo
            Componente = "Verificação parcial: $($inconclusivos.Count) componentes inconclusivos; consulte o CSV de verificação"
            Categoria = ''; VersaoAtual = ''; VersaoNova = ''; Criticidade = ''; DataDeLancamento = ''; NomeDoPacote = ''
        }
    }
    Export-DellReport -Linhas $linhas -Arquivo $Arquivo -Hostname $Hostname -ServiceTag $ServiceTag -Modelo $Modelo
    $auditoria = [IO.Path]::Combine([IO.Path]::GetDirectoryName($Arquivo), ([IO.Path]::GetFileNameWithoutExtension($Arquivo) + '_Verificacao.csv'))
    $texto = @($Verificacoes | ConvertTo-Csv -Delimiter ';' -NoTypeInformation)
    [IO.File]::WriteAllLines($auditoria, [string[]]$texto, (New-Object Text.UTF8Encoding($true)))
    Write-Log "Pendências confirmadas: $($pendentes.Count); componentes inconclusivos: $($inconclusivos.Count)."
    Write-Log "Verificação por componente: $auditoria"
}

function Assert-CatalogModelCoverage {
    param([string]$Arquivo, [string]$Modelo)
    $config = New-Object Xml.XmlReaderSettings
    $config.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $config.XmlResolver = $null
    $doc = New-Object Xml.XmlDocument
    $doc.XmlResolver = $null
    $reader = [Xml.XmlReader]::Create($Arquivo, $config)
    try { $doc.Load($reader) } finally { $reader.Close() }
    $chave = ($Modelo -replace '(?i)^PowerEdge\s+', '' -replace '\s+', '').ToLowerInvariant()
    foreach ($item in $doc.SelectNodes('//*[local-name()="SupportedSystems"]//*[local-name()="Model"]')) {
        $nome = ((Get-DisplayText $item) -replace '(?i)^PowerEdge\s+', '' -replace '\s+', '').ToLowerInvariant()
        if ($nome -eq $chave) { Write-Log "O modelo $Modelo está listado no catálogo de componentes."; return }
    }
    throw "O modelo '$Modelo' não está listado em SupportedSystems neste catálogo. Verificação inconclusiva. Use -Fonte Site ou um catálogo comprovadamente compatível; não é seguro declarar ausência de atualizações."
}

# Preparação e execução. Falhas nunca geram um CSV de sucesso vazio.
$temporario = $null
$tlsAnterior = [Net.ServicePointManager]::SecurityProtocol
try {
    # Mantém compatibilidade com chamadas antigas que informam apenas -Catalogo.
    if ($PSBoundParameters.ContainsKey('Catalogo') -and -not $PSBoundParameters.ContainsKey('Fonte')) { $Fonte = 'Catalogo' }
    Assert-DellInputParameters -Fonte $Fonte -ArquivoSiteDell $ArquivoSiteDell -ArquivoInventario $ArquivoInventario -CatalogoInformado ($PSBoundParameters.ContainsKey('Catalogo'))
    try {
        if ([string]::IsNullOrWhiteSpace($CaminhoSaida)) { $CaminhoSaida = Join-Path $PSScriptRoot 'Relatorios' }
        $CaminhoSaida = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CaminhoSaida)
        [void][IO.Directory]::CreateDirectory($CaminhoSaida)
        $CaminhoSaida = (Get-Item -LiteralPath $CaminhoSaida).FullName
        $hostnameLocal = [Environment]::MachineName
        $prefixo = 'DSU_{0}_{1}_{2}' -f $hostnameLocal, (Get-Date -Format 'yyyy-MM-dd_HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 6))
        $script:ArquivoLog = Join-Path $CaminhoSaida ($prefixo + '.log')
        $script:Diagnostico = Join-Path $CaminhoSaida ($prefixo + '_diagnostico')
        [void][IO.Directory]::CreateDirectory($script:Diagnostico)
        Write-Log 'Iniciando relatório Dell. Nenhuma atualização será instalada.'
    }
    catch { throw "Sem permissão de gravação ou caminho de saída indisponível: '$CaminhoSaida'. $($_.Exception.Message)" }

    $identidade = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identidade)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Permissão insuficiente. Abra o Windows PowerShell com Executar como administrador.'
    }
    Write-Log 'Coletando hostname, Service Tag e modelo pelo CIM local.'
    $bios = Get-CimInstance -ClassName Win32_BIOS
    $sistema = Get-CimInstance -ClassName Win32_ComputerSystem
    $serviceTag = ([string]$bios.SerialNumber).Trim()
    $modelo = ([string]$sistema.Model).Trim()
    if (-not $serviceTag -or -not $modelo) { throw 'CIM não retornou Service Tag e/ou modelo do servidor.' }
    if ($sistema.Manufacturer -notmatch 'Dell') { throw "Fabricante '$($sistema.Manufacturer)' não corresponde a Dell. Execute no PowerEdge alvo." }
    Write-Log "Servidor: $hostnameLocal; ServiceTag: $serviceTag; modelo: $modelo."

    # Adiciona TLS 1.2 sem desabilitar a validação de certificados do Windows.
    [Net.ServicePointManager]::SecurityProtocol = $tlsAnterior -bor [Net.SecurityProtocolType]::Tls12
    if ($Fonte -eq 'Site') {
        $sistemaOperacional = Get-CimInstance -ClassName Win32_OperatingSystem
        if ($sistemaOperacional.ProductType -eq 1) { throw 'Execute no Windows Server alvo, não em um Windows cliente.' }
        $produto = Get-DellProductCode -Modelo $modelo -Informado $CodigoProduto
        $so = Get-DellOsCode -Legenda ([string]$sistemaOperacional.Caption) -Informado $CodigoSO
        $origemSite = if ($ArquivoSiteDell) { 'arquivo HAR manual' } else { 'site Dell online' }
        Write-Log "Fonte: $origemSite; consulta=$ConsultaSite; produto=$produto; Windows=$($sistemaOperacional.Caption); código SO=$so."
        $dadosSite = Get-DellSiteReference -ArquivoSiteDell $ArquivoSiteDell -Produto $produto -SO $so -Pasta $script:Diagnostico -ServiceTag $serviceTag -Consulta $ConsultaSite
        if ($ArquivoInventario) {
            $caminhoInventario = (Get-Item -LiteralPath $ArquivoInventario -ErrorAction Stop).FullName
            $inventario = @(Import-DsuInventory -Arquivo $caminhoInventario -Pasta $script:Diagnostico)
            Write-Log "Usando inventário já coletado: $caminhoInventario; modificado em $((Get-Item -LiteralPath $caminhoInventario).LastWriteTime.ToString('o'))."
            Write-Log 'O arquivo importado deve pertencer a este servidor. A importação de texto/XML não comprova a identidade nem a atualidade da máquina de origem.' 'AVISO'
        }
        else {
            $dsu = Find-DsuExecutable $CaminhoDSU
            $ajuda = Invoke-DsuReadOnly $dsu @('--help') 'help' 1
            if ($ajuda.ExitCode -ne 0) { throw "Ajuda do DSU falhou (código $($ajuda.ExitCode))." }
            $inventario = @(Get-DsuSiteInventory -Executavel $dsu -Ajuda $ajuda.Text -Pasta $script:Diagnostico -LimiteMinutos $TempoLimiteDSUMinutos)
        }
        $driversWindows = @()
        try {
            $driversWindows = @(Get-DellWindowsNetworkDrivers)
            Write-Log "Drivers de rede locais dos perfis Dell implementados: $($driversWindows.Count). Consulta CIM, sem Windows Update."
        }
        catch { Write-Log "Não foi possível obter drivers de rede pelo CIM: $($_.Exception.Message). Os casos sem evidência permanecem inconclusivos." 'AVISO' }
        [IO.File]::WriteAllText((Join-Path $script:Diagnostico 'drivers-windows.json'), (ConvertTo-Json -InputObject @($driversWindows) -Depth 5), (New-Object Text.UTF8Encoding($true)))
        [IO.File]::WriteAllText((Join-Path $script:Diagnostico 'inventory.normalizado.json'), (ConvertTo-Json -InputObject @($inventario) -Depth 5), (New-Object Text.UTF8Encoding($true)))
        Write-Log "Inventário interpretado: $($inventario.Count) componentes. Comparando com os downloads do site."
        $verificacoes = @(New-SiteAssessmentRows -Inventario $inventario -Downloads $dadosSite.DriverListData -Hostname $hostnameLocal -ServiceTag $serviceTag -Modelo $modelo -SO $so -DriversWindows $driversWindows)
        $csv = Join-Path $CaminhoSaida ($prefixo + '.csv')
        Export-SiteAssessment -Verificacoes $verificacoes -Arquivo $csv -Hostname $hostnameLocal -ServiceTag $serviceTag -Modelo $modelo
        Write-Log "CSV gerado: $csv"
        Write-Log "Diagnóstico: $script:Diagnostico"
        Write-Output $csv
        return
    }

    $dsu = Find-DsuExecutable $CaminhoDSU
    Write-Log "Executável DSU: $dsu; versão do arquivo: $((Get-Item -LiteralPath $dsu).VersionInfo.FileVersion)"
    $ajuda = Invoke-DsuReadOnly $dsu @('--help') 'help' 1
    if ($ajuda.ExitCode -ne 0) { throw "Ajuda do DSU falhou (código $($ajuda.ExitCode))." }
    Assert-DsuHelp $ajuda.Text
    $temporario = Join-Path ([IO.Path]::GetTempPath()) ('DellDsuReport_' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($temporario)
    $snapshot = Get-CatalogSnapshot $Catalogo $temporario
    Assert-CatalogModelCoverage -Arquivo $snapshot.XmlPath -Modelo $modelo
    $indice = Read-DellCatalog $snapshot.XmlPath
    $argsPreview = @(Get-DsuArguments -Modo Preview -CatalogoLocal $snapshot.DsuPath)
    $previewBruto = Invoke-DsuReadOnly $dsu $argsPreview 'preview' $TempoLimiteDSUMinutos
    $preview = ConvertFrom-DsuPreviewText $previewBruto.Text $previewBruto.ExitCode
    $linhas = @()
    if (-not $preview.SemPendencias) {
        $inventarioBruto = Invoke-DsuReadOnly $dsu @(Get-DsuArguments -Modo Inventario) 'inventory' $TempoLimiteDSUMinutos
        if ($inventarioBruto.ExitCode -ne 0) { throw "Inventário DSU falhou (código $($inventarioBruto.ExitCode)). Consulte inventory.stdout.txt e inventory.stderr.txt." }
        $inventario = @(ConvertFrom-DsuInventoryText $inventarioBruto.Text)
        if ($inventario.Count -eq 0) { throw 'Inventário vazio ou formato desconhecido. Ajuste ConvertFrom-DsuInventoryText conforme inventory.stdout.txt.' }
        $linhas = @(New-DellReportRows -Pendencias $preview.Itens -Indice $indice -Inventario $inventario -Hostname $hostnameLocal -ServiceTag $serviceTag -Modelo $modelo)
    }
    Write-Log "Pendências DSU: $($preview.Itens.Count); pendências de BIOS/firmware/drivers incluídas: $($linhas.Count)."
    $csv = Join-Path $CaminhoSaida ($prefixo + '.csv')
    Export-DellReport -Linhas $linhas -Arquivo $csv -Hostname $hostnameLocal -ServiceTag $serviceTag -Modelo $modelo
    Write-Log "CSV gerado: $csv"
    Write-Log "Diagnóstico: $script:Diagnostico"
    Write-Output $csv
}
catch {
    $mensagemErro = $_.Exception.Message
    try { Write-Log $mensagemErro 'ERRO' } catch { Write-Warning "Também não foi possível gravar no log: $($_.Exception.Message)" }
    throw "Relatório Dell não concluído: $mensagemErro"
}
finally {
    [Net.ServicePointManager]::SecurityProtocol = $tlsAnterior
    if ($temporario -and (Test-Path -LiteralPath $temporario)) {
        # Só remove o diretório exclusivo criado nesta execução, abaixo do TEMP local.
        $tempRaiz = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $tempResolvido = [IO.Path]::GetFullPath($temporario)
        if ($tempResolvido.StartsWith($tempRaiz, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $tempResolvido) -match '^DellDsuReport_[0-9a-f]{32}$') {
            try { Remove-Item -LiteralPath $tempResolvido -Recurse -Force -ErrorAction Stop }
            catch { Write-Warning "Não foi possível remover o temporário '$tempResolvido': $($_.Exception.Message)" }
        }
    }
}
