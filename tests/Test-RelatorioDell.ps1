#requires -Version 5.1
<#
.SYNOPSIS
Testes offline do relatorio Dell, sem DSU, rede ou acesso ao hardware.
.DESCRIPTION
Carrega somente definicoes de funcoes pelo AST do PowerShell. O bloco principal
de Gerar-RelatorioDell.ps1 nunca e executado. Nao requer Pester.
#>
[CmdletBinding()]
param(
    [string]$Script
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (-not $Script) {
    # Em powershell.exe -File, PSScriptRoot pode estar vazio na expressao de param.
    $Script = Join-Path (Split-Path -Parent $PSScriptRoot) 'Gerar-RelatorioDell.ps1'
}
$script:Sucessos = 0
$script:Falhas = New-Object 'System.Collections.Generic.List[string]'
$script:Mensagens = New-Object 'System.Collections.Generic.List[string]'

# Analisa o codigo como texto UTF-8 e executa apenas as definicoes das funcoes.
$tokens = $null
$erros = $null
$codigo = [IO.File]::ReadAllText((Get-Item -LiteralPath $Script).FullName, [Text.Encoding]::UTF8)
$ast = [Management.Automation.Language.Parser]::ParseInput($codigo, [ref]$tokens, [ref]$erros)
if ($erros.Count -gt 0) { throw ('Erro de sintaxe no script principal: ' + ($erros -join '; ')) }
$funcoes = $ast.FindAll({ param($no) $no -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)
foreach ($funcao in $funcoes) {
    . ([scriptblock]::Create($funcao.Extent.Text))
}

# Substitui somente a gravacao de log para manter os testes silenciosos/offline.
function Write-Log {
    param([string]$Mensagem, [string]$Nivel = 'INFO')
    $script:Mensagens.Add("[$Nivel] $Mensagem")
}

function Assert-True {
    param([bool]$Condicao, [string]$Mensagem = 'Condicao nao satisfeita.')
    if (-not $Condicao) { throw $Mensagem }
}

function Assert-Equal {
    param($Esperado, $Obtido, [string]$Mensagem = 'Valores diferentes.')
    if ($Esperado -cne $Obtido) {
        throw "$Mensagem Esperado=<$Esperado>; obtido=<$Obtido>."
    }
}

function Assert-Throws {
    param([scriptblock]$Acao)
    $lancou = $false
    try { & $Acao | Out-Null } catch { $lancou = $true }
    if (-not $lancou) { throw 'A operacao deveria falhar, mas foi aceita.' }
}

function Test-Case {
    param([string]$Nome, [scriptblock]$Acao)
    try {
        & $Acao
        $script:Sucessos++
        Write-Host "OK: $Nome"
    }
    catch {
        $script:Falhas.Add("${Nome}: $($_.Exception.Message)")
        Write-Host "FALHOU: ${Nome}: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Cada execucao usa pasta exclusiva e so remove esta pasta ao terminar.
$pastaTeste = Join-Path $PSScriptRoot ('temporario_' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($pastaTeste)

try {
    $previewQuatro = @'
DELL System Update 1.9.2.0
------------------ Update Preview -----------------
# : Component : Version : Filename
---------------------------------------------------
1 : BIOS : 2.0.0 : BIOS_TESTE_WN64_2.0.0.EXE
2 : NIC Alfa : 3.0.0 : NIC_TESTE_WN64_3.0.0.EXE
NOTE: The preview option displays the components which can be updated based on Catalog.
Exiting DSU!
'@
    $previewCinco = @'
[123]: ------------------ Update Preview -----------------
[123]: # : Type : Component : Version : Filename
[123]: ---------------------------------------------------
[123]: 1 : BIOS : BIOS : 2.0.0 : BIOS_TESTE_WN64_2.0.0.EXE
[123]: 2 : Firmware : NIC Alfa : 3.0.0 : NIC_TESTE_WN64_3.0.0.EXE
[123]: NOTE: This option does not update.
'@

    Test-Case 'Preview com quatro colunas preserva a versao de destino' {
        $resultado = ConvertFrom-DsuPreviewText -Texto $previewQuatro -ExitCode 0
        Assert-Equal 2 $resultado.Itens.Count
        Assert-Equal 'BIOS' $resultado.Itens[0].Nome
        Assert-Equal '2.0.0' $resultado.Itens[0].VersaoNova
        Assert-Equal 'BIOS_TESTE_WN64_2.0.0.EXE' $resultado.Itens[0].Pacote
        Assert-True (-not $resultado.SemPendencias)
    }
    Test-Case 'Preview com cinco colunas e prefixo PID' {
        $resultado = ConvertFrom-DsuPreviewText -Texto $previewCinco -ExitCode 0
        Assert-Equal 2 $resultado.Itens.Count
        Assert-Equal 'NIC Alfa' $resultado.Itens[1].Nome
        Assert-Equal '3.0.0' $resultado.Itens[1].VersaoNova
        Assert-Equal 'NIC_TESTE_WN64_3.0.0.EXE' $resultado.Itens[1].Pacote
    }
    Test-Case 'Preview aceita campo Filename na proxima linha' {
        $texto = "# : Component : Version : Filename`n1 : BIOS : 2.0.0 :`nBIOS_TESTE_WN64_2.0.0.EXE`nNOTE: fim"
        $resultado = ConvertFrom-DsuPreviewText -Texto $texto -ExitCode 0
        Assert-Equal 'BIOS_TESTE_WN64_2.0.0.EXE' $resultado.Itens[0].Pacote
    }
    Test-Case 'Preview aceita quebra dentro do nome do pacote' {
        $texto = "# : Component : Version : Filename`n1 : BIOS : 2.0.0 : BIOS_TESTE_WN64_`n2.0.0.EXE`nNOTE: fim"
        $resultado = ConvertFrom-DsuPreviewText -Texto $texto -ExitCode 0
        Assert-Equal 'BIOS_TESTE_WN64_2.0.0.EXE' $resultado.Itens[0].Pacote
    }
    Test-Case 'Preview vazio com retorno zero falha' {
        Assert-Throws { ConvertFrom-DsuPreviewText -Texto '' -ExitCode 0 }
        Assert-Throws { ConvertFrom-DsuPreviewText -Texto "# : Component : Version : Filename`n------" -ExitCode 0 }
    }
    Test-Case 'Preview em formato desconhecido falha' {
        Assert-Throws { ConvertFrom-DsuPreviewText -Texto 'Lista de atualizacoes: BIOS 2.0' -ExitCode 0 }
        Assert-Throws { ConvertFrom-DsuPreviewText -Texto "# : Component : Version : Filename`n1 : BIOS : 2.0" -ExitCode 0 }
    }
    Test-Case 'Codigo 34 gera resultado sem pendencias' {
        $resultado = ConvertFrom-DsuPreviewText -Texto 'Exiting DSU!' -ExitCode 34
        Assert-True $resultado.SemPendencias
        Assert-Equal 0 $resultado.Itens.Count
    }
    Test-Case 'Mensagem explicita sem atualizacoes com retorno zero' {
        $resultado = ConvertFrom-DsuPreviewText -Texto 'No applicable updates found.' -ExitCode 0
        Assert-True $resultado.SemPendencias
    }
    Test-Case 'Codigos de erro nunca produzem sucesso vazio' {
        foreach ($retorno in @(1, 2, 6, 7, 14, 44, -1073740940)) {
            Assert-Throws { ConvertFrom-DsuPreviewText -Texto 'No applicable updates found.' -ExitCode $retorno }
        }
    }
    Test-Case 'Preview contraditorio nao e aceito' {
        Assert-Throws { ConvertFrom-DsuPreviewText -Texto $previewQuatro -ExitCode 34 }
        Assert-Throws { ConvertFrom-DsuPreviewText -Texto ($previewQuatro + "`nNo applicable updates found.") -ExitCode 0 }
    }
    Test-Case 'Retorno 34 nao mascara erro de inventario ou tabela desconhecida' {
        Assert-Throws { ConvertFrom-DsuPreviewText -Texto 'Could not get the inventory' -ExitCode 34 }
        Assert-Throws { ConvertFrom-DsuPreviewText -Texto "# : Component : Installed : Target : Package`n1 : BIOS : 1.0 : 2.0 : BIOS.EXE" -ExitCode 34 }
    }

    $inventarioTexto = @'
Getting System Inventory ...
1. BIOS ( Version : 1.0.0 )
2. FRMW, NIC Alfa ( Version : 2.0.0 )
3. DRVR, NIC Alfa ( Version : 8.0.0 )
4. FRMW, Disco Alfa ( Version : AA01 )
5. FRMW, Disco Alfa ( Version : AA02 )
6. APAC, Ferramenta, versao 1.0, A00 ( Version : 1.0 )
7. FRMW, Controladora PCIe (slot 1) ( Version : 4.0.0 )
'@
    $inventario = @(ConvertFrom-DsuInventoryText -Texto $inventarioTexto)

    Test-Case 'Inventario preserva nomes com virgulas e parenteses' {
        Assert-Equal 7 $inventario.Count
        Assert-Equal 'BIOS' $inventario[0].Nome
        Assert-Equal 'FRMW' $inventario[1].Tipo
        Assert-Equal 'Ferramenta, versao 1.0, A00' $inventario[5].Nome
        Assert-Equal 'Controladora PCIe (slot 1)' $inventario[6].Nome
    }
    Test-Case 'Versao instalada distingue firmware de driver pelo tipo' {
        Assert-Equal '2.0.0' (Resolve-InstalledVersion -Inventario $inventario -Nome 'NIC Alfa' -Tipo FRMW)
        Assert-Equal '8.0.0' (Resolve-InstalledVersion -Inventario $inventario -Nome 'NIC Alfa' -Tipo DRVR)
        Assert-Equal '1.0.0' (Resolve-InstalledVersion -Inventario $inventario -Nome BIOS -Tipo BIOS)
    }
    Test-Case 'Inventario agrupa multiplas versoes sem escolher uma arbitrariamente' {
        Assert-Equal 'Múltiplas: AA01 | AA02' (Resolve-InstalledVersion -Inventario $inventario -Nome 'Disco Alfa' -Tipo FRMW)
        Assert-Equal 'Não identificada' (Resolve-InstalledVersion -Inventario $inventario -Nome 'NIC Beta' -Tipo FRMW)
    }

    # Fragmentos contiguos verificam que XmlReader nao pula componentes vizinhos.
    $catalogoXml = @'
<?xml version="1.0" encoding="utf-8"?>
<Manifest xmlns="urn:dell:test">
<SoftwareComponent path="FOLDER/1/BIOS_TESTE_WN64_2.0.0.EXE" vendorVersion="2.0.0" releaseID="AAAAA" releaseDate="October 1, 2026"><Name><Display lang="en">Dell BIOS</Display></Name><ComponentType value="BIOS"/><Category value="BI"><Display lang="en">BIOS</Display></Category><Criticality value="1"><Display lang="en">Recommended</Display></Criticality></SoftwareComponent><SoftwareComponent path="FOLDER/1/NIC_TESTE_WN64_3.0.0.EXE" vendorVersion="3.0.0" releaseDate="2026-10-02"><Name><Display lang="en">NIC Firmware</Display></Name><ComponentType value="FRMW"/><Category value="NI"><Display lang="en">Network</Display></Category><Criticality value="2"><Display lang="en">Urgent</Display></Criticality></SoftwareComponent><SoftwareComponent path="FOLDER/1/NIC_DRIVER_WN64_9.0.0.EXE" vendorVersion="9.0.0" releaseDate="2026-10-03"><Name><Display lang="en">NIC Driver</Display></Name><ComponentType value="DRVR"/><Category><Display lang="en">Network</Display></Category><Criticality value="3"><Display lang="en">Optional</Display></Criticality></SoftwareComponent><SoftwareComponent path="FOLDER/1/DISK_TESTE_WN64_AA03.EXE" vendorVersion="AA03" releaseDate="2026-10-04"><Name><Display lang="en">Disk Firmware</Display></Name><ComponentType value="FRMW"/><Category><Display lang="en">SAS Drive</Display></Category><Criticality value="2"/></SoftwareComponent><SoftwareComponent path="FOLDER/1/APP_TESTE_WN64_2.0.EXE" vendorVersion="2.0"><Name><Display lang="en">Dell App</Display></Name><ComponentType value="APAC"/><Criticality value="2"><Display lang="en">Urgent</Display></Criticality></SoftwareComponent><SoftwareComponent path="FOLDER/1/UNKNOWN_TESTE.EXE" vendorVersion="1.0"><Name><Display lang="en">Unknown criticality</Display></Name><ComponentType value="FRMW"/><Criticality value="9"/></SoftwareComponent>
</Manifest>
'@
    $arquivoCatalogo = Join-Path $pastaTeste 'catalogo.xml'
    [IO.File]::WriteAllText($arquivoCatalogo, $catalogoXml, (New-Object Text.UTF8Encoding($true)))
    $indice = Read-DellCatalog -Arquivo $arquivoCatalogo

    Test-Case 'Catalogo com namespace inclui todos os componentes contiguos' {
        Assert-Equal 6 $indice.Count
        Assert-True ($indice.ContainsKey('bios_teste_wn64_2.0.0'))
        Assert-True ($indice.ContainsKey('unknown_teste'))
        Assert-Equal '2026-10-01' $indice['bios_teste_wn64_2.0.0'][0].Data
    }
    Test-Case 'Criticidade usa Display real e aprende fallback do proprio catalogo' {
        Assert-Equal 'Recomendado' $indice['bios_teste_wn64_2.0.0'][0].Criticidade
        Assert-Equal 'Urgente' $indice['nic_teste_wn64_3.0.0'][0].Criticidade
        Assert-Equal 'Opcional' $indice['nic_driver_wn64_9.0.0'][0].Criticidade
        Assert-Equal 'Urgente' $indice['disk_teste_wn64_aa03'][0].Criticidade
        Assert-Equal 'Não informada' $indice['unknown_teste'][0].Criticidade
    }
    Test-Case 'Codigo numerico isolado nao recebe traducao presumida' {
        $arquivo = Join-Path $pastaTeste 'sem-display.xml'
        [IO.File]::WriteAllText($arquivo, '<Manifest><SoftwareComponent path="BIOS.EXE"><ComponentType value="BIOS"/><Criticality value="1"/></SoftwareComponent></Manifest>')
        $semDisplay = Read-DellCatalog -Arquivo $arquivo
        Assert-Equal 'Não informada' $semDisplay['bios'][0].Criticidade
    }
    Test-Case 'Catalogo com codigos inconsistentes falha' {
        $inconsistente = $catalogoXml.Replace('<Criticality value="2"><Display lang="en">Urgent</Display></Criticality></SoftwareComponent><SoftwareComponent path="FOLDER/1/UNKNOWN', '<Criticality value="2"><Display lang="en">Optional</Display></Criticality></SoftwareComponent><SoftwareComponent path="FOLDER/1/UNKNOWN')
        Assert-True ($inconsistente -ne $catalogoXml) 'A fixture inconsistente nao foi modificada.'
        $arquivo = Join-Path $pastaTeste 'inconsistente.xml'
        [IO.File]::WriteAllText($arquivo, $inconsistente)
        Assert-Throws { Read-DellCatalog -Arquivo $arquivo }
    }
    Test-Case 'Catalogo de indice e XML malformado falham' {
        $arquivo = Join-Path $pastaTeste 'indice.xml'
        [IO.File]::WriteAllText($arquivo, '<Manifest><Catalog/></Manifest>')
        Assert-Throws { Read-DellCatalog -Arquivo $arquivo }
        [IO.File]::WriteAllText($arquivo, '<Manifest><SoftwareComponent>')
        Assert-Throws { Read-DellCatalog -Arquivo $arquivo }
    }

    $pendencias = @(
        [pscustomobject]@{ Nome = 'BIOS'; VersaoNova = '2.0.0'; Pacote = 'BIOS_TESTE_WN64_2.0.0.EXE' }
        [pscustomobject]@{ Nome = 'NIC Alfa'; VersaoNova = '3.0.0'; Pacote = 'nic_teste_wn64_3.0.0' }
        [pscustomobject]@{ Nome = 'NIC Alfa'; VersaoNova = '9.0.0'; Pacote = 'NIC_DRIVER_WN64_9.0.0.EXE' }
        [pscustomobject]@{ Nome = 'Disco Alfa'; VersaoNova = 'AA03'; Pacote = 'FOLDER/1/DISK_TESTE_WN64_AA03.EXE' }
        [pscustomobject]@{ Nome = 'Dell App'; VersaoNova = '2.0'; Pacote = 'APP_TESTE_WN64_2.0.EXE' }
    )
    $linhas = @(New-DellReportRows -Pendencias $pendencias -Indice $indice -Inventario $inventario -Hostname 'SRV-TESTE' -ServiceTag ABC1234 -Modelo 'PowerEdge R750')

    Test-Case 'Join exato por arquivo exclui aplicativos e preserva dez colunas' {
        Assert-Equal 4 $linhas.Count
        Assert-Equal 'Hostname,ServiceTag,Modelo,Componente,Categoria,VersaoAtual,VersaoNova,Criticidade,DataDeLancamento,NomeDoPacote' (($linhas[0].PSObject.Properties.Name) -join ',')
        Assert-Equal 'SRV-TESTE' $linhas[0].Hostname
        Assert-Equal 'ABC1234' $linhas[0].ServiceTag
        Assert-Equal 'PowerEdge R750' $linhas[0].Modelo
        Assert-Equal '1.0.0' $linhas[0].VersaoAtual
        Assert-Equal '2.0.0' $linhas[1].VersaoAtual
        Assert-Equal '8.0.0' $linhas[2].VersaoAtual
        Assert-Equal 'Múltiplas: AA01 | AA02' $linhas[3].VersaoAtual
        Assert-Equal 'Network' $linhas[1].Categoria
    }
    Test-Case 'Pacote parecido nunca substitui join exato ausente' {
        $semCorrespondencia = [pscustomobject]@{ Nome = 'BIOS'; VersaoNova = '2.0.0'; Pacote = 'BIOS_TESTE_WN64_2.0.EXE' }
        Assert-Throws { New-DellReportRows -Pendencias @($semCorrespondencia) -Indice $indice -Inventario $inventario -Hostname X -ServiceTag Y -Modelo Z }
    }
    Test-Case 'Join duplicado so e resolvido com VendorVersion inequivoco' {
        $duplicado = @{}
        foreach ($chave in $indice.Keys) { $duplicado[$chave] = $indice[$chave] }
        $lista = New-Object 'System.Collections.Generic.List[object]'
        $original = $indice['bios_teste_wn64_2.0.0'][0]
        $lista.Add($original)
        $alternativo = $original.PSObject.Copy()
        $alternativo.VendorVersion = '1.9.0'
        $lista.Add($alternativo)
        $duplicado['bios_teste_wn64_2.0.0'] = $lista
        $resolvido = @(New-DellReportRows -Pendencias @($pendencias[0]) -Indice $duplicado -Inventario $inventario -Hostname X -ServiceTag Y -Modelo Z)
        Assert-Equal 1 $resolvido.Count
        $alternativo.VendorVersion = '2.0.0'
        Assert-Throws { New-DellReportRows -Pendencias @($pendencias[0]) -Indice $duplicado -Inventario $inventario -Hostname X -ServiceTag Y -Modelo Z }
    }
    Test-Case 'CSV tem BOM UTF-8, ponto e virgula e criticidade ordenada' {
        $arquivo = Join-Path $pastaTeste 'relatorio.csv'
        Export-DellReport -Linhas $linhas -Arquivo $arquivo -Hostname X -ServiceTag Y -Modelo Z
        $bytes = [IO.File]::ReadAllBytes($arquivo)
        Assert-True ($bytes.Length -gt 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) 'BOM UTF-8 ausente.'
        $primeiraLinha = [IO.File]::ReadAllLines($arquivo, [Text.Encoding]::UTF8)[0]
        Assert-Equal '"Hostname";"ServiceTag";"Modelo";"Componente";"Categoria";"VersaoAtual";"VersaoNova";"Criticidade";"DataDeLancamento";"NomeDoPacote"' $primeiraLinha
        $csv = @(Import-Csv -LiteralPath $arquivo -Delimiter ';' -Encoding UTF8)
        Assert-Equal 'Urgente,Urgente,Recomendado,Opcional' (($csv.Criticidade) -join ',')
        Assert-Equal 'Múltiplas: AA01 | AA02' $csv[0].VersaoAtual
        Assert-True (-not (Test-Path -LiteralPath ($arquivo + '.tmp'))) 'Arquivo temporario permaneceu apos exportar.'
    }
    Test-Case 'CSV sem pendencias contem linha explicita e dados do servidor' {
        $arquivo = Join-Path $pastaTeste 'sem-pendencias.csv'
        Export-DellReport -Linhas @() -Arquivo $arquivo -Hostname SRV0 -ServiceTag TAG0 -Modelo 'PowerEdge R650'
        $csv = @(Import-Csv -LiteralPath $arquivo -Delimiter ';' -Encoding UTF8)
        Assert-Equal 1 $csv.Count
        Assert-Equal 'Nenhuma atualização pendente' $csv[0].Componente
        Assert-Equal 'SRV0' $csv[0].Hostname
        Assert-Equal 'TAG0' $csv[0].ServiceTag
        Assert-Equal 'PowerEdge R650' $csv[0].Modelo
    }
    # Regressão real do SRV-EXEMPLO: inventário fornecido pelo operador + registros
    # resumidos da API Dell. Não consulta a rede nem executa DSU nestes testes.
    $inventarioRealTexto = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures\Inventario-R530.txt'))
    $siteJson = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures\dell-r530-resumo.json'))
    $site = ConvertFrom-DellSiteResponse -Texto $siteJson -Produto 'poweredge-r530'
    $inventarioReal = @(Get-ValidatedInventory -Texto $inventarioRealTexto -ExigirEncerramento)
    $avaliacoes = @(New-SiteAssessmentRows -Inventario $inventarioReal -Downloads $site.DriverListData -Hostname SRV-EXEMPLO -ServiceTag TESTE -Modelo 'PowerEdge R530' -SO W12R2)

    Test-Case 'Modelo e SO reais sao convertidos sem usar o filtro do navegador' {
        Assert-Equal 'poweredge-r530' (Get-DellProductCode 'PowerEdge R530')
        Assert-Equal 'W12R2' (Get-DellOsCode 'Microsoft Windows Server 2012 R2 Standard')
        Assert-Equal 'WST14' (Get-DellOsCode 'Microsoft Windows Server 2016 Datacenter')
        Assert-Equal 'WS19L' (Get-DellOsCode 'Microsoft Windows Server 2019 Standard')
        Assert-Equal 'WS22L' (Get-DellOsCode 'Microsoft Windows Server 2022 Standard')
        Assert-Equal 'WS25L' (Get-DellOsCode 'Microsoft Windows Server 2025 Standard')
        Assert-Throws { Get-DellOsCode 'Microsoft Windows 11 Pro' }
        Assert-Throws { Get-DellProductCode 'Precision 5820' }
    }
    Test-Case 'API aceita JSON e interpreta criticidade pelo texto, sem mapa XML' {
        Assert-Equal 6 @($site.DriverListData).Count
        $biosSite = @($avaliacoes | Where-Object Componente -eq BIOS)[0]
        Assert-Equal 'Urgente' $biosSite.Criticidade
        Assert-Equal 'Pendente' $biosSite.Status
    }
    $tokenTagTeste = '0-TOKEN_SINTETICO_1234567890'
    $registrosTagTeste = @($site.DriverListData | ForEach-Object {
        $copia = $_.PSObject.Copy()
        $marcado = if ($_.DriverId -in @('PVDNH','VWF72','700GG')) { 1 } else { 0 }
        $copia | Add-Member -NotePropertyName IsTagDriver -NotePropertyValue $marcado -Force
        $copia
    })
    $dadosTagTeste = [pscustomobject]@{ ProductCode='poweredge-r530'; IsTag=$true; ServiceTag='ABC1234'; IsNoDriversFoundForTag=$false; DriverListData=$registrosTagTeste }
    $jsonTagTeste = ConvertTo-Json -InputObject $dadosTagTeste -Depth 15

    Test-Case 'Identificador de tag e lido da URL HTTPS canonica da Dell' {
        $uri = [uri]('https://www.dell.com/support/product-details/pt-br/servicetag/' + $tokenTagTeste + '/drivers')
        Assert-Equal $tokenTagTeste (Get-DellTagToken -Html '' -UrlFinal $uri)
    }
    Test-Case 'Identificador de tag pode ser lido do contexto JSON da pagina' {
        $html = '{"EncryptedServiceTag":"' + $tokenTagTeste + '"}'
        $uri = [uri]'https://www.dell.com/support/product-details/pt-br/servicetag/ABC1234/drivers'
        Assert-Equal $tokenTagTeste (Get-DellTagToken -Html $html -UrlFinal $uri)
        $htmlEscapado = $html.Replace('"','\"')
        Assert-Equal $tokenTagTeste (Get-DellTagToken -Html $htmlEscapado -UrlFinal $uri)
    }
    Test-Case 'Pagina sem identificador, com conflito ou fora da Dell e rejeitada' {
        $uri = [uri]'https://www.dell.com/support/product-details/pt-br/servicetag/ABC1234/drivers'
        Assert-Throws { Get-DellTagToken -Html '' -UrlFinal $uri }
        $html = '{"ServiceTag":"' + $tokenTagTeste + '","EncryptedServiceTag":"0-OUTRO_TOKEN_SINTETICO_9876543210"}'
        Assert-Throws { Get-DellTagToken -Html $html -UrlFinal $uri }
        Assert-Throws { Get-DellTagToken -Html '' -UrlFinal ([uri]('https://outro.exemplo/servicetag/' + $tokenTagTeste + '/drivers')) }
        Assert-Throws { Get-DellTagToken -Html '' -UrlFinal ([uri]('http://www.dell.com/servicetag/' + $tokenTagTeste + '/drivers')) }
    }
    Test-Case 'Consulta por tag usa apenas registros IsTagDriver positivos' {
        $r = ConvertFrom-DellSiteResponse -Texto $jsonTagTeste -Produto 'poweredge-r530' -ExigirTag -ServiceTag ABC1234 -TokenTag $tokenTagTeste
        Assert-Equal 3 @($r.DriverListData).Count
        Assert-Equal 6 $r.TotalDownloadsRecebidos
        Assert-True (@($r.DriverListData | Where-Object { $_.IsTagDriver -le 0 }).Count -eq 0)
    }
    Test-Case 'Identidade de tag retornada precisa corresponder a tag ou identificador solicitado' {
        Assert-Throws { ConvertFrom-DellSiteResponse -Texto $jsonTagTeste -Produto 'poweredge-r530' -ExigirTag -ServiceTag XYZ9999 -TokenTag '0-OUTRO_TOKEN_SINTETICO_9876543210' }
        $copia = $dadosTagTeste.PSObject.Copy()
        $copia.ServiceTag = $tokenTagTeste
        $r = ConvertFrom-DellSiteResponse -Texto (ConvertTo-Json -InputObject $copia -Depth 15) -Produto 'poweredge-r530' -ExigirTag -ServiceTag ABC1234 -TokenTag $tokenTagTeste
        Assert-Equal 3 @($r.DriverListData).Count
    }
    Test-Case 'Resposta ampla do modelo nao pode se passar por consulta por tag' {
        $copia = $dadosTagTeste.PSObject.Copy()
        $copia.IsTag = $false
        Assert-Throws { ConvertFrom-DellSiteResponse -Texto (ConvertTo-Json -InputObject $copia -Depth 15) -Produto 'poweredge-r530' -ExigirTag -ServiceTag ABC1234 -TokenTag $tokenTagTeste }
        Assert-Throws { ConvertFrom-DellSiteResponse -Texto $siteJson -Produto 'poweredge-r530' -ExigirTag -ServiceTag ABC1234 -TokenTag $tokenTagTeste }
    }
    Test-Case 'Ausencia de dados por tag nao vira ausencia de pendencias' {
        $copia = $dadosTagTeste.PSObject.Copy()
        $copia.IsNoDriversFoundForTag = $true
        Assert-Throws { ConvertFrom-DellSiteResponse -Texto (ConvertTo-Json -InputObject $copia -Depth 15) -Produto 'poweredge-r530' -ExigirTag -ServiceTag ABC1234 -TokenTag $tokenTagTeste }
        $copia.IsNoDriversFoundForTag = $false
        $copia.DriverListData = @($registrosTagTeste | ForEach-Object { $p = $_.PSObject.Copy(); $p.IsTagDriver = 0; $p })
        Assert-Throws { ConvertFrom-DellSiteResponse -Texto (ConvertTo-Json -InputObject $copia -Depth 15) -Produto 'poweredge-r530' -ExigirTag -ServiceTag ABC1234 -TokenTag $tokenTagTeste }
    }
    Test-Case 'Marcacao IsTagDriver ausente ou invalida torna consulta inconclusiva' {
        $copia = $dadosTagTeste.PSObject.Copy()
        $copia.DriverListData = @($registrosTagTeste | ForEach-Object { $p = $_.PSObject.Copy(); $p.IsTagDriver = 'indefinido'; $p })
        Assert-Throws { ConvertFrom-DellSiteResponse -Texto (ConvertTo-Json -InputObject $copia -Depth 15) -Produto 'poweredge-r530' -ExigirTag -ServiceTag ABC1234 -TokenTag $tokenTagTeste }
    }

    # HTTP e simulado para conferir URL, filtro e ausencia de fallback; estes
    # casos nao afirmam que uma Service Tag real foi aceita pela Dell online.
    $script:JsonTagHttpTeste = $jsonTagTeste
    $script:JsonModeloHttpTeste = $siteJson
    $script:TokenHttpTeste = $tokenTagTeste
    $script:StatusHttpTeste = 0
    function Invoke-WebRequest {
        param([string]$Uri, $WebSession, [switch]$UseBasicParsing, [int]$TimeoutSec, [hashtable]$Headers, $ErrorAction)
        $script:ChamadasHttpTeste += $Uri
        if ($script:FalhaHttpTeste) {
            $falhaSimulada = New-Object InvalidOperationException('Falha de acesso simulada')
            if ($script:StatusHttpTeste -gt 0) {
                $falhaSimulada | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = $script:StatusHttpTeste })
            }
            throw $falhaSimulada
        }
        if ($Uri -match '/product-details/') {
            return [pscustomobject]@{ Content=''; BaseResponse=[pscustomobject]@{ResponseUri=[uri]('https://www.dell.com/support/product-details/pt-br/servicetag/'+$script:TokenHttpTeste+'/drivers')} }
        }
        if ($Uri -match '/packdriversbytag\?') { return [pscustomobject]@{Content=$script:JsonTagHttpTeste} }
        if ($Uri -match '/packdriversbyproduct\?') { return [pscustomobject]@{Content=$script:JsonModeloHttpTeste} }
        throw 'URL HTTP de teste inesperada'
    }
    try {
        Test-Case 'Consulta experimental explicita por tag grava respostas bruta e filtrada' {
            $script:ChamadasHttpTeste = @(); $script:FalhaHttpTeste = $false
            $pasta = Join-Path $pastaTeste 'http-tag'; [void][IO.Directory]::CreateDirectory($pasta)
            $r = Get-DellSiteDownloads -Consulta ServiceTag -Produto 'poweredge-r530' -SO W12R2 -Pasta $pasta -ServiceTag ABC1234
            Assert-Equal 2 $script:ChamadasHttpTeste.Count
            Assert-True ($script:ChamadasHttpTeste[0] -match '/servicetag/ABC1234/drivers')
            Assert-True ($script:ChamadasHttpTeste[1] -match '/packdriversbytag\?.*servicetag=0-TOKEN_SINTETICO_1234567890')
            Assert-True (@($script:ChamadasHttpTeste | Where-Object { $_ -match 'packdriversbyproduct' }).Count -eq 0)
            Assert-Equal 3 @($r.DriverListData).Count
            $bruta = [IO.File]::ReadAllText((Join-Path $pasta 'downloads-site-resposta.json')) | ConvertFrom-Json
            Assert-Equal 6 @($bruta.DriverListData).Count
            $fonte = [IO.File]::ReadAllText((Join-Path $pasta 'fonte-site.txt'))
            Assert-True ($fonte -match 'Consulta=ServiceTag' -and $fonte -match 'RegistrosRecebidos=6' -and $fonte -match 'RegistrosUsados=3')
        }
        Test-Case 'Padrao usa modelo e SO sem consultar pagina por tag' {
            $script:ChamadasHttpTeste = @(); $script:FalhaHttpTeste = $false
            $pasta = Join-Path $pastaTeste 'http-modelo'; [void][IO.Directory]::CreateDirectory($pasta)
            $parametroConsulta = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'ConsultaSite' })[0]
            Assert-Equal 'Modelo' $parametroConsulta.DefaultValue.Value
            $r = Get-DellSiteDownloads -Produto 'poweredge-r530' -SO W12R2 -Pasta $pasta -ServiceTag ABC1234
            Assert-Equal 1 $script:ChamadasHttpTeste.Count
            Assert-True ($script:ChamadasHttpTeste[0] -match 'packdriversbyproduct')
            Assert-Equal 6 @($r.DriverListData).Count
        }
        Test-Case 'Bloqueio HTTP por tag interrompe sem tentar API do modelo' {
            $script:ChamadasHttpTeste = @(); $script:FalhaHttpTeste = $true
            Assert-Throws { Get-DellSiteDownloads -Consulta ServiceTag -Produto 'poweredge-r530' -SO W12R2 -Pasta $pastaTeste -ServiceTag ABC1234 }
            Assert-Equal 1 $script:ChamadasHttpTeste.Count
            Assert-True (@($script:ChamadasHttpTeste | Where-Object { $_ -match 'packdriversbyproduct' }).Count -eq 0)
        }
        Test-Case 'Tag ausente ou invalida e rejeitada antes de requisicoes HTTP' {
            $script:ChamadasHttpTeste = @(); $script:FalhaHttpTeste = $false
            Assert-Throws { Get-DellSiteDownloads -Consulta ServiceTag -Produto 'poweredge-r530' -SO W12R2 -Pasta $pastaTeste }
            Assert-Throws { Get-DellSiteDownloads -Consulta ServiceTag -Produto 'poweredge-r530' -SO W12R2 -Pasta $pastaTeste -ServiceTag '../outra' }
            Assert-Equal 0 $script:ChamadasHttpTeste.Count
        }
        Test-Case 'HTTP 403 na pagina explica bloqueio e opcao explicita sem gerar sucesso' {
            $script:ChamadasHttpTeste = @(); $script:FalhaHttpTeste = $true; $script:StatusHttpTeste = 403
            $pasta = Join-Path $pastaTeste 'http-403'; [void][IO.Directory]::CreateDirectory($pasta)
            $mensagem = ''
            try { Get-DellSiteDownloads -Consulta ServiceTag -Produto 'poweredge-r530' -SO W12R2 -Pasta $pasta -ServiceTag ABC1234 | Out-Null }
            catch { $mensagem = $_.Exception.Message }
            finally { $script:StatusHttpTeste = 0; $script:FalhaHttpTeste = $false }
            Assert-True ($mensagem -match '^HTTP 403:' -and $mensagem -match '-ConsultaSite Modelo' -and $mensagem -match 'não foi realizada')
            Assert-Equal 1 $script:ChamadasHttpTeste.Count
            Assert-Equal 0 @(Get-ChildItem -LiteralPath $pasta).Count
        }
        Test-Case 'Falha sem resposta HTTP nao e diagnosticada como 403' {
            $script:ChamadasHttpTeste = @(); $script:FalhaHttpTeste = $true; $script:StatusHttpTeste = 0
            $mensagem = ''
            try { Get-DellSiteDownloads -Consulta ServiceTag -Produto 'poweredge-r530' -SO W12R2 -Pasta $pastaTeste -ServiceTag ABC1234 | Out-Null }
            catch { $mensagem = $_.Exception.Message }
            finally { $script:FalhaHttpTeste = $false }
            Assert-True ($mensagem -match 'Falha de acesso simulada' -and $mensagem -notmatch '403')
            Assert-Equal 1 $script:ChamadasHttpTeste.Count
        }
        Test-Case 'HTTP 403 na API do modelo informa que a verificacao nao foi realizada' {
            $script:ChamadasHttpTeste = @(); $script:FalhaHttpTeste = $true; $script:StatusHttpTeste = 403
            $mensagem = ''
            try { Get-DellSiteDownloads -Produto 'poweredge-r530' -SO W12R2 -Pasta $pastaTeste -Consulta Modelo | Out-Null }
            catch { $mensagem = $_.Exception.Message }
            finally { $script:StatusHttpTeste = 0; $script:FalhaHttpTeste = $false }
            Assert-True ($mensagem -match '^HTTP 403:' -and $mensagem -match 'API interna' -and $mensagem -match 'consulta Modelo')
            Assert-Equal 1 $script:ChamadasHttpTeste.Count
        }
        Test-Case 'Fallback de resposta por tag para modelo e rejeitado sem nova consulta' {
            $script:ChamadasHttpTeste = @(); $script:FalhaHttpTeste = $false
            $anterior = $script:JsonTagHttpTeste; $script:JsonTagHttpTeste = $siteJson
            try { Assert-Throws { Get-DellSiteDownloads -Consulta ServiceTag -Produto 'poweredge-r530' -SO W12R2 -Pasta $pastaTeste -ServiceTag ABC1234 } }
            finally { $script:JsonTagHttpTeste = $anterior }
            Assert-Equal 2 $script:ChamadasHttpTeste.Count
        }
    }
    finally { Remove-Item -LiteralPath Function:\Invoke-WebRequest }
    # HARs abaixo sao sinteticos: preservam o schema do navegador e reutilizam
    # somente os seis registros publicos do fixture. Nenhum HAR de cliente e salvo.
    function New-HarTestEntry {
        param(
            [string]$Texto,
            [string]$Url = 'https://www.dell.com/support/driver/en-us/dep/api/driverlist/packdriversbyproduct?productcode=poweredge-r530&oscode=W12R2&lob=PowerEdge',
            [int]$Status = 200,
            [string]$Encoding = '',
            [string]$CapturadoEm = '2026-10-29T13:00:00.000Z'
        )
        $conteudo = [pscustomobject]@{ text = $Texto; mimeType = 'text/plain'; size = ([Text.Encoding]::UTF8.GetByteCount($Texto)) }
        if ($Encoding) { $conteudo | Add-Member -NotePropertyName encoding -NotePropertyValue $Encoding }
        return [pscustomobject]@{
            startedDateTime = $CapturadoEm
            request = [pscustomobject]@{ method = 'GET'; url = $Url; headers = @(); cookies = @() }
            response = [pscustomobject]@{ status = $Status; content = $conteudo; headers = @(); cookies = @() }
        }
    }
    function Write-HarTestFile {
        param([object[]]$Entradas)
        $arquivoHar = Join-Path $pastaTeste ('captura_' + [guid]::NewGuid().ToString('N') + '.har')
        $har = [pscustomobject]@{ log = [pscustomobject]@{ version = '1.2'; creator = [pscustomobject]@{ name = 'Harness sintetico'; version = '1' }; entries = @($Entradas) } }
        [IO.File]::WriteAllText($arquivoHar, (ConvertTo-Json -InputObject $har -Depth 35), (New-Object Text.UTF8Encoding($true)))
        return $arquivoHar
    }
    function New-HarTestDiagnostic {
        $pastaHar = Join-Path $pastaTeste ('har_' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($pastaHar)
        return $pastaHar
    }
    $urlTagHar = 'https://www.dell.com/support/driver/en-us/dep/api/driverlist/packdriversbytag?productcode=poweredge-r530&oscode=W12R2&lob=PowerEdge&servicetag=' + $tokenTagTeste
    $script:ChamadasRedeHar = 0
    function Invoke-WebRequest {
        $script:ChamadasRedeHar++
        throw 'Um importador local nao pode consultar a rede.'
    }
    try {
        Test-Case 'HAR manual e roteador importam sem HTTP e preservam metadados da captura' {
            $arquivoHar = Write-HarTestFile -Entradas @((New-HarTestEntry -Texto $siteJson))
            $diagnosticoHar = New-HarTestDiagnostic
            $r = Get-DellSiteReference -ArquivoSiteDell $arquivoHar -Produto 'poweredge-r530' -SO W12R2 -Pasta $diagnosticoHar -ServiceTag ABC1234 -Consulta Modelo
            Assert-Equal 6 @($r.DriverListData).Count
            Assert-Equal 0 $script:ChamadasRedeHar
            $fonteHar = [IO.File]::ReadAllText((Join-Path $diagnosticoHar 'fonte-site.txt'))
            foreach ($campo in @('Fonte=ArquivoHAR', 'Consulta=Modelo', 'Produto=poweredge-r530', 'SO=W12R2', 'RegistrosRecebidos=6', 'RegistrosUsados=6', 'EntradaHAR=')) {
                Assert-True ($fonteHar.Contains($campo)) "Metadado ausente: $campo"
            }
            Assert-True ($fonteHar -match ('SHA256=' + (Get-FileHash -LiteralPath $arquivoHar -Algorithm SHA256).Hash))
            Assert-True ($fonteHar -match 'CapturadoEm=.*2026-10-29')
            Assert-True (Test-Path -LiteralPath (Join-Path $diagnosticoHar 'downloads-site-resposta.json'))
            Assert-True (Test-Path -LiteralPath (Join-Path $diagnosticoHar 'downloads-site.json'))
        }
        Test-Case 'HAR suporta corpo Dell rotacionado dentro de base64 do navegador' {
            $rotHar = New-Object Text.StringBuilder
            foreach ($ch in $siteJson.ToCharArray()) {
                $n = [int]$ch
                if ($n -ge 65 -and $n -le 90) { $ch = [char](($n - 65 + 3) % 26 + 65) }
                elseif ($n -ge 97 -and $n -le 122) { $ch = [char](($n - 97 + 3) % 26 + 97) }
                [void]$rotHar.Append($ch)
            }
            $base64Har = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($rotHar.ToString()))
            $arquivoHar = Write-HarTestFile -Entradas @((New-HarTestEntry -Texto $base64Har -Encoding base64))
            $r = Import-DellSiteHar -Arquivo $arquivoHar -Produto 'poweredge-r530' -SO W12R2 -Pasta (New-HarTestDiagnostic) -ServiceTag ABC1234
            Assert-Equal 'PVDNH' $r.DriverListData[0].DriverId
            Assert-Equal 6 @($r.DriverListData).Count
        }
        Test-Case 'HAR grande com requisicao irrelevante acima de dois MiB e aceito no PS 5.1' {
            $ruido = New-HarTestEntry -Texto ('x' * 2200000) -Url 'https://www.dell.com/imagem.txt'
            $arquivoHar = Write-HarTestFile -Entradas @($ruido, (New-HarTestEntry -Texto $siteJson))
            $r = Import-DellSiteHar -Arquivo $arquivoHar -Produto 'poweredge-r530' -SO W12R2 -Pasta (New-HarTestDiagnostic) -ServiceTag ABC1234
            Assert-Equal 6 @($r.DriverListData).Count
        }
        Test-Case 'HAR ausente, diretorio ou acima do limite nao e carregado' {
            Assert-Throws { Import-DellSiteHar -Arquivo (Join-Path $pastaTeste 'inexistente.har') -Produto 'poweredge-r530' -SO W12R2 -Pasta $pastaTeste -ServiceTag ABC1234 }
            Assert-Throws { Import-DellSiteHar -Arquivo $pastaTeste -Produto 'poweredge-r530' -SO W12R2 -Pasta $pastaTeste -ServiceTag ABC1234 }
            $grandeHar = Join-Path $pastaTeste 'maior-limite.har'
            $streamHar = [IO.File]::Open($grandeHar, [IO.FileMode]::Create, [IO.FileAccess]::Write)
            try { $streamHar.SetLength(100MB + 1) } finally { $streamHar.Dispose() }
            $mensagemHar = ''
            try { Import-DellSiteHar -Arquivo $grandeHar -Produto 'poweredge-r530' -SO W12R2 -Pasta $pastaTeste -ServiceTag ABC1234 | Out-Null }
            catch { $mensagemHar = $_.Exception.Message }
            Assert-True ($mensagemHar -match '100') 'O limite deve ser verificado antes do parsing de um HAR enorme.'
        }
        Test-Case 'HAR invalido ou sem entradas nao vira ausencia de atualizacoes' {
            foreach ($conteudoHar in @('nao e JSON', '{}', '{"log":{"entries":[]}}')) {
                $arquivoHar = Join-Path $pastaTeste ('invalido_' + [guid]::NewGuid().ToString('N') + '.har')
                [IO.File]::WriteAllText($arquivoHar, $conteudoHar)
                Assert-Throws { Import-DellSiteHar -Arquivo $arquivoHar -Produto 'poweredge-r530' -SO W12R2 -Pasta $pastaTeste -ServiceTag ABC1234 }
            }
        }
        Test-Case 'HAR seleciona modelo e SO corretos e ignora outras consultas capturadas' {
            $alvoHar = New-HarTestEntry -Texto $siteJson
            $outroSOHar = New-HarTestEntry -Texto 'ruido de outro SO' -Url $alvoHar.request.url.Replace('W12R2','WST14')
            $outroModeloHar = New-HarTestEntry -Texto 'ruido de outro modelo' -Url $alvoHar.request.url.Replace('poweredge-r530','poweredge-r740')
            $arquivoHar = Write-HarTestFile -Entradas @($outroSOHar, $alvoHar, $outroModeloHar)
            $r = Import-DellSiteHar -Arquivo $arquivoHar -Produto 'poweredge-r530' -SO W12R2 -Pasta (New-HarTestDiagnostic) -ServiceTag ABC1234
            Assert-Equal 6 @($r.DriverListData).Count
            $semAlvoHar = Write-HarTestFile -Entradas @($outroSOHar, $outroModeloHar)
            Assert-Throws { Import-DellSiteHar -Arquivo $semAlvoHar -Produto 'poweredge-r530' -SO W12R2 -Pasta $pastaTeste -ServiceTag ABC1234 }
        }
        Test-Case 'HAR nao aceita origem falsa, HTTP ou metodo divergente como downloads Dell' {
            $alvoHar = New-HarTestEntry -Texto $siteJson
            foreach ($urlInvalidaHar in @($alvoHar.request.url.Replace('www.dell.com','www.dell.com.exemplo.invalid'), $alvoHar.request.url.Replace('https:','http:'), $alvoHar.request.url.Replace('packdriversbyproduct','packdriversbyproduct-falso'))) {
                $arquivoHar = Write-HarTestFile -Entradas @((New-HarTestEntry -Texto $siteJson -Url $urlInvalidaHar))
                Assert-Throws { Import-DellSiteHar -Arquivo $arquivoHar -Produto 'poweredge-r530' -SO W12R2 -Pasta $pastaTeste -ServiceTag ABC1234 }
            }
            $alvoHar.request.method = 'POST'
            $arquivoHar = Write-HarTestFile -Entradas @($alvoHar)
            Assert-Throws { Import-DellSiteHar -Arquivo $arquivoHar -Produto 'poweredge-r530' -SO W12R2 -Pasta $pastaTeste -ServiceTag ABC1234 }
        }
        Test-Case 'HAR rejeita parametros de contexto duplicados na URL' {
            $alvoHar = New-HarTestEntry -Texto $siteJson
            foreach ($sufixoHar in @('&productcode=poweredge-r740', '&oscode=WST14')) {
                $arquivoHar = Write-HarTestFile -Entradas @((New-HarTestEntry -Texto $siteJson -Url ($alvoHar.request.url + $sufixoHar)))
                Assert-Throws { Import-DellSiteHar -Arquivo $arquivoHar -Produto 'poweredge-r530' -SO W12R2 -Pasta $pastaTeste -ServiceTag ABC1234 }
            }
        }
        Test-Case 'HAR valida produto e schema do corpo mesmo com URL correta' {
            foreach ($textoInvalidoHar in @($siteJson.Replace('poweredge-r530','poweredge-r740'), '{"ProductCode":"poweredge-r530","DriverListData":[]}', '<html>Access denied</html>')) {
                $arquivoHar = Write-HarTestFile -Entradas @((New-HarTestEntry -Texto $textoInvalidoHar))
                Assert-Throws { Import-DellSiteHar -Arquivo $arquivoHar -Produto 'poweredge-r530' -SO W12R2 -Pasta $pastaTeste -ServiceTag ABC1234 }
            }
        }
        Test-Case 'HAR com erro ou corpo ausente no alvo nao usa resposta anterior como sucesso' {
            $bomHar = New-HarTestEntry -Texto $siteJson
            $falhaHar = New-HarTestEntry -Texto $siteJson -Status 403
            $vazioHar = New-HarTestEntry -Texto ''
            $omitidoHar = New-HarTestEntry -Texto $siteJson
            $omitidoHar.response.content.PSObject.Properties.Remove('text')
            foreach ($ruimHar in @($falhaHar, $vazioHar, $omitidoHar)) {
                $arquivoHar = Write-HarTestFile -Entradas @($bomHar, $ruimHar)
                Assert-Throws { Import-DellSiteHar -Arquivo $arquivoHar -Produto 'poweredge-r530' -SO W12R2 -Pasta $pastaTeste -ServiceTag ABC1234 }
            }
        }
        Test-Case 'HAR rejeita codificacao desconhecida e base64 invalida' {
            foreach ($ruimHar in @((New-HarTestEntry -Texto $siteJson -Encoding gzip), (New-HarTestEntry -Texto '!!!BASE64_INVALIDA!!!' -Encoding base64))) {
                $arquivoHar = Write-HarTestFile -Entradas @($ruimHar)
                Assert-Throws { Import-DellSiteHar -Arquivo $arquivoHar -Produto 'poweredge-r530' -SO W12R2 -Pasta $pastaTeste -ServiceTag ABC1234 }
            }
        }
        Test-Case 'HAR aceita duplicatas identicas e registra a ultima captura' {
            $primeiroHar = New-HarTestEntry -Texto $siteJson -CapturadoEm '2026-10-28T13:00:00.000Z'
            $ultimoHar = New-HarTestEntry -Texto $siteJson -CapturadoEm '2026-10-29T14:30:00.000Z'
            $arquivoHar = Write-HarTestFile -Entradas @($primeiroHar, $ultimoHar)
            $diagnosticoHar = New-HarTestDiagnostic
            $r = Import-DellSiteHar -Arquivo $arquivoHar -Produto 'poweredge-r530' -SO W12R2 -Pasta $diagnosticoHar -ServiceTag ABC1234
            Assert-Equal 6 @($r.DriverListData).Count
            $fonteHar = [IO.File]::ReadAllText((Join-Path $diagnosticoHar 'fonte-site.txt'))
            Assert-True ($fonteHar -match 'CapturadoEm=.*2026-10-29T14:30:00')
            Assert-True ($fonteHar -match 'EntradaHAR=')
        }
        Test-Case 'HAR rejeita respostas conflitantes em corpo, endpoint ou tag' {
            $bomHar = New-HarTestEntry -Texto $siteJson
            $outroCorpoHar = New-HarTestEntry -Texto $siteJson.Replace('2.19.0','2.20.0')
            $outroEndpointHar = New-HarTestEntry -Texto $siteJson -Url $urlTagHar
            foreach ($conflitoHar in @($outroCorpoHar, $outroEndpointHar)) {
                $arquivoHar = Write-HarTestFile -Entradas @($bomHar, $conflitoHar)
                Assert-Throws { Import-DellSiteHar -Arquivo $arquivoHar -Produto 'poweredge-r530' -SO W12R2 -Pasta $pastaTeste -ServiceTag ABC1234 }
            }
            $primeiraTagHar = New-HarTestEntry -Texto $jsonTagTeste -Url $urlTagHar
            $outraTagHar = New-HarTestEntry -Texto $jsonTagTeste -Url $urlTagHar.Replace($tokenTagTeste,'0-OUTRO_TOKEN_SINTETICO_9876543210')
            $arquivoHar = Write-HarTestFile -Entradas @($primeiraTagHar, $outraTagHar)
            Assert-Throws { Import-DellSiteHar -Arquivo $arquivoHar -Produto 'poweredge-r530' -SO W12R2 -Pasta $pastaTeste -ServiceTag ABC1234 }
        }
        Test-Case 'HAR exige data de captura valida antes de usar os downloads' {
            $semDataHar = New-HarTestEntry -Texto $siteJson
            $semDataHar.PSObject.Properties.Remove('startedDateTime')
            $dataInvalidaHar = New-HarTestEntry -Texto $siteJson -CapturadoEm 'data desconhecida'
            foreach ($ruimHar in @($semDataHar, $dataInvalidaHar)) {
                $arquivoHar = Write-HarTestFile -Entradas @($ruimHar)
                Assert-Throws { Import-DellSiteHar -Arquivo $arquivoHar -Produto 'poweredge-r530' -SO W12R2 -Pasta $pastaTeste -ServiceTag ABC1234 }
            }
        }
        Test-Case 'HAR no padrao Modelo usa lista ampla de endpoint tag e sinaliza o escopo' {
            $arquivoHar = Write-HarTestFile -Entradas @((New-HarTestEntry -Texto $jsonTagTeste -Url $urlTagHar))
            $diagnosticoHar = New-HarTestDiagnostic
            $inicioMensagensHar = $script:Mensagens.Count
            $r = Import-DellSiteHar -Arquivo $arquivoHar -Produto 'poweredge-r530' -SO W12R2 -Pasta $diagnosticoHar -ServiceTag ABC1234
            Assert-Equal 6 @($r.DriverListData).Count
            $fonteHar = [IO.File]::ReadAllText((Join-Path $diagnosticoHar 'fonte-site.txt'))
            Assert-True ($fonteHar -match 'Consulta=Modelo' -and $fonteHar -match 'RegistrosUsados=6')
            $mensagensHar = @($script:Mensagens | Select-Object -Skip $inicioMensagensHar) -join "`n"
            Assert-True ($mensagensHar -match '\[AVISO\].*(modelo|ampla)')
        }
        Test-Case 'HAR com tag clara correspondente filtra registros positivos no modo ServiceTag' {
            $arquivoHar = Write-HarTestFile -Entradas @((New-HarTestEntry -Texto $jsonTagTeste -Url $urlTagHar))
            $diagnosticoHar = New-HarTestDiagnostic
            $r = Import-DellSiteHar -Arquivo $arquivoHar -Produto 'poweredge-r530' -SO W12R2 -Pasta $diagnosticoHar -ServiceTag ABC1234 -Consulta ServiceTag
            Assert-Equal 3 @($r.DriverListData).Count
            Assert-Equal 'PVDNH,VWF72,700GG' (($r.DriverListData | ForEach-Object DriverId) -join ',')
            $brutaHar = [IO.File]::ReadAllText((Join-Path $diagnosticoHar 'downloads-site-resposta.json')) | ConvertFrom-Json
            $filtradaHar = [IO.File]::ReadAllText((Join-Path $diagnosticoHar 'downloads-site.json')) | ConvertFrom-Json
            Assert-Equal 6 @($brutaHar.DriverListData).Count
            Assert-Equal 3 @($filtradaHar.DriverListData).Count
        }
        Test-Case 'HAR ServiceTag rejeita identidade opaca ou diferente da tag do BIOS' {
            foreach ($identidadeHar in @($tokenTagTeste, 'XYZ9999')) {
                $copiaHar = $dadosTagTeste.PSObject.Copy(); $copiaHar.ServiceTag = $identidadeHar
                $arquivoHar = Write-HarTestFile -Entradas @((New-HarTestEntry -Texto (ConvertTo-Json -InputObject $copiaHar -Depth 20) -Url $urlTagHar))
                Assert-Throws { Import-DellSiteHar -Arquivo $arquivoHar -Produto 'poweredge-r530' -SO W12R2 -Pasta $pastaTeste -ServiceTag ABC1234 -Consulta ServiceTag }
            }
            $arquivoModeloHar = Write-HarTestFile -Entradas @((New-HarTestEntry -Texto $siteJson))
            Assert-Throws { Import-DellSiteHar -Arquivo $arquivoModeloHar -Produto 'poweredge-r530' -SO W12R2 -Pasta $pastaTeste -ServiceTag ABC1234 -Consulta ServiceTag }
        }
        Test-Case 'Parametros manuais aceitam inventario local mas rejeitam catalogo' {
            Assert-DellInputParameters -Fonte Site -ArquivoSiteDell 'captura.har' -ArquivoInventario 'inventario.txt' -CatalogoInformado $false
            Assert-DellInputParameters -Fonte Site -ArquivoSiteDell '' -ArquivoInventario '' -CatalogoInformado $false
            Assert-Throws { Assert-DellInputParameters -Fonte Catalogo -ArquivoSiteDell 'captura.har' -ArquivoInventario '' -CatalogoInformado $false }
            Assert-Throws { Assert-DellInputParameters -Fonte Site -ArquivoSiteDell 'captura.har' -ArquivoInventario '' -CatalogoInformado $true }
        }
        Test-Case 'HAR normaliza somente dados necessarios sem copiar cookies, headers ou token opaco' {
            $copiaHar = $dadosTagTeste.PSObject.Copy()
            $copiaHar | Add-Member -NotePropertyName SegredoIgnorado -NotePropertyValue 'SENTINELA_CORPO_PRIVADO'
            $entradaPrivadaHar = New-HarTestEntry -Texto (ConvertTo-Json -InputObject $copiaHar -Depth 20) -Url $urlTagHar
            $entradaPrivadaHar.request.headers = @([pscustomobject]@{ name = 'Authorization'; value = 'SENTINELA_AUTH_PRIVADA' })
            $entradaPrivadaHar.request.cookies = @([pscustomobject]@{ name = 'sessao'; value = 'SENTINELA_COOKIE_PRIVADO' })
            $entradaPrivadaHar.response.headers = @([pscustomobject]@{ name = 'Set-Cookie'; value = 'SENTINELA_SETCOOKIE_PRIVADO' })
            $arquivoHar = Write-HarTestFile -Entradas @($entradaPrivadaHar)
            $diagnosticoHar = New-HarTestDiagnostic
            $inicioMensagensHar = $script:Mensagens.Count
            $r = Import-DellSiteHar -Arquivo $arquivoHar -Produto 'poweredge-r530' -SO W12R2 -Pasta $diagnosticoHar -ServiceTag ABC1234
            Assert-Equal 6 @($r.DriverListData).Count
            $persistidoHar = (@(Get-ChildItem -LiteralPath $diagnosticoHar -File | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n")
            $mensagensHar = @($script:Mensagens | Select-Object -Skip $inicioMensagensHar) -join "`n"
            Assert-True (($persistidoHar + $mensagensHar) -notmatch 'SENTINELA_|0-TOKEN_SINTETICO_1234567890')
            Assert-Equal 0 @(Get-ChildItem -LiteralPath $diagnosticoHar -Filter '*.har').Count
        }
        Test-Case 'HAR produz a mesma avaliacao de pendencias que a referencia existente' {
            $arquivoHar = Write-HarTestFile -Entradas @((New-HarTestEntry -Texto $siteJson))
            $r = Import-DellSiteHar -Arquivo $arquivoHar -Produto 'poweredge-r530' -SO W12R2 -Pasta (New-HarTestDiagnostic) -ServiceTag ABC1234
            $avaliacoesHar = @(New-SiteAssessmentRows -Inventario $inventarioReal -Downloads $r.DriverListData -Hostname SRV-EXEMPLO -ServiceTag TESTE -Modelo 'PowerEdge R530' -SO W12R2)
            Assert-Equal $avaliacoes.Count $avaliacoesHar.Count
            Assert-Equal 2 @($avaliacoesHar | Where-Object Status -eq Pendente).Count
            Assert-Equal 16 @($avaliacoesHar | Where-Object Status -eq Inconclusivo).Count
            for ($iHar = 0; $iHar -lt $avaliacoes.Count; $iHar++) {
                foreach ($colunaHar in @('Componente', 'VersaoAtual', 'VersaoNova', 'Criticidade', 'Status', 'NomeDoPacote')) {
                    Assert-Equal (Get-ObjectValue $avaliacoes[$iHar] $colunaHar) (Get-ObjectValue $avaliacoesHar[$iHar] $colunaHar)
                }
            }
            Assert-Equal 0 $script:ChamadasRedeHar
        }
    }
    finally { Remove-Item -LiteralPath Function:\Invoke-WebRequest }

    Test-Case 'API decodifica a transformacao publicada pelo JavaScript Dell' {
        $rot = New-Object Text.StringBuilder
        foreach ($ch in $siteJson.ToCharArray()) {
            $n = [int]$ch
            if ($n -ge 65 -and $n -le 90) { $ch = [char](($n - 65 + 3) % 26 + 65) }
            elseif ($n -ge 97 -and $n -le 122) { $ch = [char](($n - 97 + 3) % 26 + 97) }
            [void]$rot.Append($ch)
        }
        $decodificado = ConvertFrom-DellSiteResponse -Texto $rot.ToString() -Produto 'poweredge-r530'
        Assert-Equal 'PVDNH' $decodificado.DriverListData[0].DriverId
    }
    Test-Case 'Resposta de produto errado, vazia ou bloqueada nunca significa atualizado' {
        Assert-Throws { ConvertFrom-DellSiteResponse -Texto $siteJson -Produto 'poweredge-r640' }
        Assert-Throws { ConvertFrom-DellSiteResponse -Texto '{"ProductCode":"poweredge-r530","DriverListData":[]}' -Produto 'poweredge-r530' }
        Assert-Throws { ConvertFrom-DellSiteResponse -Texto '<html>Access Denied</html>' -Produto 'poweredge-r530' }
        Assert-Throws { ConvertFrom-DellSiteResponse -Texto '{"ProductCode":"poweredge-r530","DriverListData":[{"DriverId":"PVDNH"}]}' -Produto 'poweredge-r530' }
    }
    Test-Case 'Inventario real preserva as 25 linhas e exige encerramento na importacao' {
        Assert-Equal 25 $inventarioReal.Count
        Assert-Throws { Get-ValidatedInventory -Texto ($inventarioRealTexto -replace 'Exiting DSU!', '') -ExigirEncerramento }
        Assert-Throws { Get-ValidatedInventory -Texto ($inventarioRealTexto + "`n26. formato desconhecido") -ExigirEncerramento }
    }
    Test-Case 'Versoes numericas nao usam ordem alfabetica nem aceitam zeros ficticios' {
        Assert-Equal -1 (Compare-DottedVersion '2.5.4' '2.19.0')
        Assert-Equal -1 (Compare-DottedVersion '25.5.3.0005' '25.5.9.0001')
        Assert-Equal 0 (Compare-DottedVersion '2.19.0.0' '2.19.0')
        Assert-Equal 1 (Compare-DottedVersion '2.20.0' '2.19.0')
        Assert-True ($null -eq (Compare-DottedVersion '0.0.0' '21.40.2'))
        Assert-True ($null -eq (Compare-DottedVersion 'EG02' 'EG03'))
    }
    Test-Case 'Inventario com falha textual nao e aceito mesmo com linha de encerramento' {
        Assert-Throws { Get-ValidatedInventory -Texto ($inventarioRealTexto + "`nCould not get the inventory") -ExigirEncerramento }
    }
    Test-Case 'Registro sem tipo e preservado como inconclusivo, sem ser descartado' {
        $semTipo = @([pscustomobject]@{ Nome = 'BIOS'; Tipo = ''; Versao = '2.5.4' })
        $r = @(New-SiteAssessmentRows $semTipo $site.DriverListData X Y 'PowerEdge R530' W12R2)
        Assert-Equal 1 $r.Count
        Assert-Equal 'Inconclusivo' $r[0].Status
    }
    Test-Case 'SRV-EXEMPLO confirma BIOS e PERC, sem declarar os demais atualizados' {
        Assert-Equal 19 $avaliacoes.Count
        Assert-Equal 2 @($avaliacoes | Where-Object Status -eq Pendente).Count
        Assert-Equal 16 @($avaliacoes | Where-Object Status -eq Inconclusivo).Count
        $biosSite = @($avaliacoes | Where-Object Componente -eq BIOS)[0]
        Assert-Equal '2.19.0' $biosSite.VersaoNova
        $percSite = @($avaliacoes | Where-Object Componente -like 'PERC H730P*')[0]
        Assert-Equal '25.5.9.0001' $percSite.VersaoNova
        Assert-Equal 'Recomendado' $percSite.Criticidade
        $idracSite = @($avaliacoes | Where-Object Componente -eq 'Integrated Dell Remote Access Controller')[0]
        Assert-Equal 'Atualizado na referência' $idracSite.Status
        Assert-Equal '2.86.86.86' $idracSite.VersaoNova
    }
    Test-Case 'Disco ligado a PERC nunca recebe o firmware da propria controladora' {
        $discos = @($avaliacoes | Where-Object Componente -like 'Firmware for*')
        Assert-Equal 4 $discos.Count
        foreach ($disco in $discos) {
            Assert-Equal 'Inconclusivo' $disco.Status
            Assert-Equal '' $disco.VersaoNova
            Assert-Equal '' $disco.NomeDoPacote
        }
    }
    Test-Case 'NIC generica e driver zero nao sao comparados com versao do pacote' {
        $nics = @($avaliacoes | Where-Object Componente -like '*NetXtreme*')
        Assert-Equal 7 $nics.Count
        foreach ($nic in $nics) { Assert-Equal 'Inconclusivo' $nic.Status }
        Assert-True (@($nics | Where-Object { $_.Motivo -match 'zero' }).Count -eq 1)
    }
    Test-Case 'PERC H730 nao e confundida com H730P por prefixo de nome' {
        $outra = @([pscustomobject]@{ Nome = 'PERC H730 Mini Firmware'; Tipo = 'FRMW'; Versao = '25.5.3.0005' })
        $soH730P = @($site.DriverListData | Where-Object DriverId -eq '700GG' | ForEach-Object { $copia = $_.PSObject.Copy(); $copia.DriverName = 'Dell PERC H730P Firmware'; $copia })
        $r = @(New-SiteAssessmentRows $outra $soH730P X Y 'PowerEdge R530' W12R2)
        Assert-Equal 'Inconclusivo' $r[0].Status
    }
    Test-Case 'Comparacao nao sugere downgrade quando inventario esta acima do site' {
        $novo = @([pscustomobject]@{ Nome = 'BIOS'; Tipo = 'BIOS'; Versao = '2.20.0' })
        $r = @(New-SiteAssessmentRows $novo $site.DriverListData X Y 'PowerEdge R530' W12R2)
        Assert-Equal 'Acima da referência' $r[0].Status
    }
    Test-Case 'API com duas versoes na mesma data resulta inconclusiva' {
        $biosA = @($site.DriverListData | Where-Object Type -eq BIOS)[0]
        $biosB = $biosA.PSObject.Copy()
        $biosB.DellVer = '2.21.0, A00'
        $r = @(New-SiteAssessmentRows @([pscustomobject]@{Nome='BIOS';Tipo='BIOS';Versao='2.5.4'}) @($biosA,$biosB) X Y 'PowerEdge R530' W12R2)
        Assert-Equal 'Inconclusivo' $r[0].Status
    }
    Test-Case 'Catalogo sem cobertura do modelo interrompe em vez de emitir nenhuma pendencia' {
        $arquivo = Join-Path $pastaTeste 'cobertura.xml'
        [IO.File]::WriteAllText($arquivo, '<Manifest><SoftwareComponent><SupportedSystems><Brand><Model><Display lang="en">R640</Display></Model></Brand></SupportedSystems></SoftwareComponent></Manifest>')
        Assert-CatalogModelCoverage -Arquivo $arquivo -Modelo 'PowerEdge R640'
        Assert-Throws { Assert-CatalogModelCoverage -Arquivo $arquivo -Modelo 'PowerEdge R530' }
    }
    Test-Case 'CSV do site preserva dez colunas, ordem e aviso de verificacao parcial' {
        $arquivo = Join-Path $pastaTeste 'site.csv'
        Export-SiteAssessment -Verificacoes $avaliacoes -Arquivo $arquivo -Hostname SRV-EXEMPLO -ServiceTag TESTE -Modelo 'PowerEdge R530'
        $r = @(Import-Csv -LiteralPath $arquivo -Delimiter ';' -Encoding UTF8)
        Assert-Equal 3 $r.Count
        Assert-Equal 10 @($r[0].PSObject.Properties).Count
        Assert-Equal 'BIOS' $r[0].Componente
        Assert-Equal 'Urgente' $r[0].Criticidade
        Assert-Equal 'Recomendado' $r[1].Criticidade
        Assert-True ($r[2].Componente -like 'Verificação parcial: 16*')
        $verificacaoCsv = @(Import-Csv -LiteralPath (Join-Path $pastaTeste 'site_Verificacao.csv') -Delimiter ';' -Encoding UTF8)
        Assert-Equal 19 $verificacaoCsv.Count
        Assert-True (@($verificacaoCsv | Where-Object Status -eq Inconclusivo).Count -eq 16)
    }
    Test-Case 'Somente inconclusivos nunca produz CSV nenhuma atualizacao pendente' {
        $arquivo = Join-Path $pastaTeste 'parcial.csv'
        Export-SiteAssessment -Verificacoes @($avaliacoes | Where-Object Status -eq Inconclusivo) -Arquivo $arquivo -Hostname X -ServiceTag Y -Modelo Z
        $r = @(Import-Csv -LiteralPath $arquivo -Delimiter ';' -Encoding UTF8)
        Assert-Equal 1 $r.Count
        Assert-True ($r[0].Componente -like 'Verificação parcial:*')
    }
    Test-Case 'Somente comparacoes concluidas e sem pendencia permite linha nenhuma' {
        $arquivo = Join-Path $pastaTeste 'atualizado.csv'
        Export-SiteAssessment -Verificacoes @($avaliacoes | Where-Object Status -eq 'Atualizado na referência') -Arquivo $arquivo -Hostname X -ServiceTag Y -Modelo Z
        $r = @(Import-Csv -LiteralPath $arquivo -Delimiter ';' -Encoding UTF8)
        Assert-Equal 'Nenhuma atualização pendente' $r[0].Componente
    }
    Test-Case 'Leitura compartilhada aceita arquivo ainda aberto para escrita' {
        $arquivo = Join-Path $pastaTeste 'aberto.txt'
        $writer = [IO.File]::Open($arquivo, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes($inventarioRealTexto)
            $writer.Write($bytes, 0, $bytes.Length)
            $writer.Flush()
            $r = @(Get-ValidatedInventory -Texto (Read-SharedText $arquivo) -ExigirEncerramento)
            Assert-Equal 25 $r.Count
        }
        finally { $writer.Dispose() }
    }
    # XML reduzido e sem identidade de cliente; IDs e versões reais preservados.
    $xmlTexto = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures\Inventario-R530.xml'))
    $xmlInventario = @(ConvertFrom-DsuInventoryXml -Texto $xmlTexto)
    $siteDiscos = ConvertFrom-DellSiteResponse -Texto ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures\dell-r530-discos.json'))) -Produto 'poweredge-r530'
    $downloadsXml = @($site.DriverListData) + @($siteDiscos.DriverListData)
    $avaliacoesXml = @(New-SiteAssessmentRows $xmlInventario $downloadsXml SRV-EXEMPLO TESTE 'PowerEdge R530' WST14)
    $discosXml = @($xmlInventario | Where-Object { $_.FQDD -like 'Disk.Bay.*' })

    Test-Case 'XML preserva todas as instancias e identifica discos atras da PERC' {
        Assert-Equal 25 $xmlInventario.Count
        Assert-Equal 4 $discosXml.Count
        Assert-Equal 'MG04SCA20ENY' $discosXml[0].ModeloDispositivo
        Assert-Equal '105266' $discosXml[0].ComponentID
        Assert-True ($discosXml[0].Nome -like 'Firmware for*Disk 0*')
        Assert-Equal 'EG02' $discosXml[0].Versao
        Assert-Equal 'EG03' $discosXml[1].Versao
        Assert-True ($discosXml[0].FQDD -ne $discosXml[1].FQDD)
        $nic = @($xmlInventario | Where-Object VendorID -eq '14E4')[0]
        Assert-Equal '165F' $nic.DeviceID
        Assert-Equal '2003' $nic.SubDeviceID
        Assert-Equal '14E4' $nic.SubVendorID
        Assert-Equal '5' $nic.Bus
        Assert-Equal '0' $nic.Function
    }
    Test-Case 'XML UTF-16 com BOM e importado sem perder versoes ou modelos' {
        $arquivo = Join-Path $pastaTeste 'unicode.xml'
        [IO.File]::WriteAllText($arquivo, ($xmlTexto -replace 'utf-8', 'UTF-16'), [Text.Encoding]::Unicode)
        $r = @(Import-DsuInventory -Arquivo $arquivo -Pasta $pastaTeste)
        Assert-Equal 25 $r.Count
        Assert-Equal 'MG04SCA20ENY' $r[8].ModeloDispositivo
        Assert-Equal 25 @(Import-DsuInventory -Arquivo (Join-Path $pastaTeste 'inventory.importado.xml')).Count
        $snapshot = New-Object Xml.XmlDocument
        $snapshot.Load((Join-Path $pastaTeste 'inventory.importado.xml'))
        Assert-Equal 'UTF-8' $snapshot.FirstChild.Encoding
    }
    Test-Case 'Importacao textual continua compativel e exige encerramento' {
        $arquivo = Join-Path $pastaTeste 'importado.txt'
        [IO.File]::WriteAllText($arquivo, $inventarioRealTexto)
        Assert-Equal 25 @(Import-DsuInventory -Arquivo $arquivo).Count
        [IO.File]::WriteAllText($arquivo, ($inventarioRealTexto -replace 'Exiting DSU!', ''))
        Assert-Throws { Import-DsuInventory -Arquivo $arquivo }
    }
    Test-Case 'XML truncado, vazio, catalogo e schema desconhecido sao rejeitados' {
        foreach ($texto in @('', '<SVMInventory schemaVersion="1.0">', '<Manifest/>', '<SVMInventory schemaVersion="2.0"/>', '<SVMInventory schemaVersion="1.0"/>')) {
            Assert-Throws { ConvertFrom-DsuInventoryXml -Texto $texto }
        }
        Assert-Throws { ConvertFrom-DsuInventoryXml -Texto ($xmlTexto -replace '<Application display="BIOS"[^>]*/>', '') }
        Assert-Throws { ConvertFrom-DsuInventoryXml -Texto ($xmlTexto -replace 'version="EG02"', 'version=""') }
    }
    Test-Case 'XML rejeita entidades externas e DTD mesmo se parecer inventario' {
        $xxe = '<!DOCTYPE SVMInventory [<!ENTITY e SYSTEM "file:///C:/Windows/win.ini">]><SVMInventory schemaVersion="1.0"><Device><Application display="&e;" version="1.0" componentType="BIOS"/></Device></SVMInventory>'
        Assert-Throws { ConvertFrom-DsuInventoryXml -Texto $xxe }
    }
    Test-Case 'Inventario acima de 10 MiB e rejeitado antes de interpretar' {
        $arquivo = Join-Path $pastaTeste 'inventario-grande.xml'
        $stream = [IO.File]::Create($arquivo)
        try { $stream.SetLength(10MB + 1) } finally { $stream.Dispose() }
        Assert-Throws { Import-DsuInventory -Arquivo $arquivo }
    }
    Test-Case 'XML permite multiplas Application sem perder dispositivo ou tipo' {
        $texto = '<SVMInventory schemaVersion="1.0"><Device display="NIC" vendorID="14E4"><Application display="NIC FW" version="1.0" componentType="FRMW"/><Application display="NIC Driver" version="2.0" componentType="DRVR"/></Device></SVMInventory>'
        $r = @(ConvertFrom-DsuInventoryXml -Texto $texto)
        Assert-Equal 2 $r.Count
        Assert-Equal 'FRMW' $r[0].Tipo
        Assert-Equal 'DRVR' $r[1].Tipo
    }
    Test-Case 'Argumentos usam XML somente se anunciado na ajuda sem opcao de instalacao' {
        $r = @(Get-SiteInventoryArguments -Ajuda '--inventory --output-inventory-xml=<FILE>' -ArquivoXml 'C:\pasta com espaco\inv.xml')
        Assert-Equal 2 $r.Count
        Assert-Equal '--inventory' $r[0]
        Assert-Equal '--output-inventory-xml=C:\pasta com espaco\inv.xml' $r[1]
        Assert-Equal 1 @(Get-SiteInventoryArguments -Ajuda '--inventory --output-inventory-xml-other' -ArquivoXml X).Count
        Assert-Throws { Get-SiteInventoryArguments -Ajuda '--preview --output-inventory-xml=<FILE>' -ArquivoXml X }
    }
    Test-Case 'Discos com identidade XML reduzem quatro inconclusivos preservando as baias' {
        Assert-Equal 19 $avaliacoesXml.Count
        Assert-Equal 5 @($avaliacoesXml | Where-Object Status -eq Pendente).Count
        Assert-Equal 12 @($avaliacoesXml | Where-Object Status -eq Inconclusivo).Count
        Assert-Equal 2 @($avaliacoesXml | Where-Object Status -eq 'Atualizado na referência').Count
        $r = @($avaliacoesXml | Where-Object { $_.FQDD -like 'Disk.Bay.*' })
        Assert-Equal 'Pendente' $r[0].Status
        Assert-Equal 'EG03' $r[0].VersaoNova
        Assert-Equal 'Atualizado na referência' $r[1].Status
        Assert-Equal 'Pendente' $r[2].Status
        Assert-Equal 'LA0C' $r[2].VersaoNova
        Assert-Equal 'Pendente' $r[3].Status
        Assert-True ($r[0].NomeDoPacote -like '*RG9MK*')
        Assert-True ($r[2].NomeDoPacote -like '*P183W*')
    }
    Test-Case 'Modelo ou ComponentID diferente e FQDD ausente nao recebem regra de disco' {
        foreach ($campo in @('ModeloDispositivo','ComponentID','FQDD','Tipo')) {
            $copia = $discosXml[0].PSObject.Copy()
            $copia.$campo = 'OUTRO'
            Assert-True ($null -eq (Get-DellDiskRule $copia))
        }
        $copia = $discosXml[2].PSObject.Copy()
        $copia.ModeloDispositivo = 'ST8000NM023B-OUTRO'
        Assert-True ($null -eq (Get-DellDiskRule $copia))
    }
    Test-Case 'DriverId ou titulo de outro disco nao e aceito por semelhanca' {
        foreach ($campo in @('DriverId','DriverName')) {
            $copia = $siteDiscos.DriverListData[0].PSObject.Copy()
            $copia.$campo = 'OUTRO'
            $r = @(New-SiteAssessmentRows @($discosXml[0]) @($copia) X Y Z WST14)
            Assert-Equal 'Inconclusivo' $r[0].Status
            Assert-Equal '' $r[0].NomeDoPacote
        }
    }
    Test-Case 'Firmware alfanumerico desconhecido nao e ordenado nem gera downgrade' {
        $regra = Get-DellDiskRule $discosXml[0]
        Assert-True ($null -eq (Compare-DellDiskVersion $regra 'EG04' 'EG03'))
        Assert-True ($null -eq (Compare-DellDiskVersion $regra 'EG01' 'EG03'))
        Assert-True ($null -eq (Compare-DellDiskVersion $regra 'EG02' 'EG04'))
        $copia = $discosXml[0].PSObject.Copy()
        $copia.Versao = 'EG04'
        $r = @(New-SiteAssessmentRows @($copia) $downloadsXml X Y Z WST14)
        Assert-Equal 'Inconclusivo' $r[0].Status
        Assert-True ($r[0].Motivo -match 'par de versões')
    }
    Test-Case 'Nova versao publicada de disco e pacote Linux permanecem inconclusivos' {
        $copia = $siteDiscos.DriverListData[0].PSObject.Copy()
        $copia.DellVer = 'EG04, A00'
        $r = @(New-SiteAssessmentRows @($discosXml[0]) @($copia) X Y Z WST14)
        Assert-Equal 'Inconclusivo' $r[0].Status
        $copia.FileFrmtInfo = [pscustomobject]@{FileName='disco.BIN';FileType='LLXP'}
        $copia.OthFileFrmts = @()
        $r = @(New-SiteAssessmentRows @($discosXml[0]) @($copia) X Y Z WST14)
        Assert-Equal '' $r[0].NomeDoPacote
    }
    Test-Case 'NIC com PCI IDs e fonte com ComponentID nao ganham regra por suposicao' {
        $r = @($avaliacoesXml | Where-Object { $_.VendorID -eq '14E4' -or $_.ComponentID -eq '101095' })
        Assert-Equal 8 $r.Count
        foreach ($item in $r) { Assert-Equal 'Inconclusivo' $item.Status }
    }
    Test-Case 'CSV XML mantem dez colunas e auditoria inclui modelo baia e PCI IDs' {
        $arquivo = Join-Path $pastaTeste 'xml.csv'
        Export-SiteAssessment $avaliacoesXml $arquivo X Y Z
        $principal = @(Import-Csv -LiteralPath $arquivo -Delimiter ';' -Encoding UTF8)
        Assert-Equal 6 $principal.Count
        Assert-Equal 10 @($principal[0].PSObject.Properties).Count
        Assert-Equal 'Urgente' $principal[0].Criticidade
        Assert-True ($principal[-1].Componente -like 'Verificação parcial: 12*')
        $auditoria = @(Import-Csv -LiteralPath (Join-Path $pastaTeste 'xml_Verificacao.csv') -Delimiter ';' -Encoding UTF8)
        Assert-Equal 19 $auditoria.Count
        Assert-Equal 'MG04SCA20ENY' $auditoria[6].ModeloDispositivo
        Assert-True (@($auditoria | Where-Object DeviceID -eq '165F').Count -eq 6)
        Assert-Equal 'EF-BB-BF' ([BitConverter]::ToString(([IO.File]::ReadAllBytes($arquivo))[0..2]))
    }
    # Simula somente o processo DSU: testa a coleta XML sem DSU nem hardware.
    $wrapperOriginal = ${function:Invoke-DsuReadOnly}
    $script:XmlColetaTeste = $xmlTexto
    $script:TextoColetaTeste = 'Exiting DSU!'
    $script:CodigoColetaTeste = 0
    $script:CriarXmlTeste = $true
    function Invoke-DsuReadOnly {
        param($Executavel, $Argumentos, $Etapa, $LimiteMinutos)
        if ($script:CriarXmlTeste -and $Argumentos.Count -gt 1) {
            [IO.File]::WriteAllText($Argumentos[1].Substring('--output-inventory-xml='.Length), $script:XmlColetaTeste)
        }
        [pscustomobject]@{Text=$script:TextoColetaTeste; ExitCode=$script:CodigoColetaTeste}
    }
    try {
        Test-Case 'Coleta automatica interpreta XML gerado pelo processo DSU' {
            Assert-Equal 25 @(Get-DsuSiteInventory DSU '--inventory --output-inventory-xml=<FILE>' $pastaTeste 1).Count
        }
        Test-Case 'XML ausente malformado e erro DSU interrompem sem fallback textual' {
            Remove-Item -LiteralPath (Join-Path $pastaTeste 'inventory.xml')
            $script:CriarXmlTeste = $false
            Assert-Throws { Get-DsuSiteInventory DSU '--inventory --output-inventory-xml=<FILE>' $pastaTeste 1 }
            $script:CriarXmlTeste = $true
            $script:XmlColetaTeste = '<incompleto>'
            Assert-Throws { Get-DsuSiteInventory DSU '--inventory --output-inventory-xml=<FILE>' $pastaTeste 1 }
            $script:XmlColetaTeste = $xmlTexto
            $script:CodigoColetaTeste = 1
            Assert-Throws { Get-DsuSiteInventory DSU '--inventory --output-inventory-xml=<FILE>' $pastaTeste 1 }
            $script:CodigoColetaTeste = 0
            $script:TextoColetaTeste = 'ERROR inventory failed'
            Assert-Throws { Get-DsuSiteInventory DSU '--inventory --output-inventory-xml=<FILE>' $pastaTeste 1 }
        }
        Test-Case 'DSU sem exportacao XML mantem coleta textual validada' {
            $script:TextoColetaTeste = $inventarioRealTexto
            Assert-Equal 25 @(Get-DsuSiteInventory DSU '--inventory' $pastaTeste 1).Count
        }
    }
    finally { ${function:Invoke-DsuReadOnly} = $wrapperOriginal }

    Test-Case 'Wrapper nativo captura stdout e stderr e encerra sem pipe bloqueado' {
        $script:Diagnostico = $pastaTeste
        $exe = Join-Path $PSHOME 'powershell.exe'
        $r = Invoke-DsuReadOnly -Executavel $exe -Argumentos @('-NoProfile', '-NonInteractive', '-Command', '[Console]::WriteLine("saida teste"); [Console]::Error.WriteLine("erro teste"); exit 0') -Etapa 'wrapper' -LimiteMinutos 1
        Assert-Equal 0 $r.ExitCode
        Assert-True ($r.Text -match 'saida teste' -and $r.Text -match 'erro teste')
    }
}
finally {
    $raizPermitida = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    $resolvido = [IO.Path]::GetFullPath($pastaTeste)
    if ($resolvido.StartsWith($raizPermitida, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvido) -match '^temporario_[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $resolvido -Recurse -Force
    }
}

Write-Host ("`nResultado: {0} testes passaram; {1} falharam." -f $script:Sucessos, $script:Falhas.Count)
if ($script:Falhas.Count -gt 0) { throw ($script:Falhas -join "`n") }
