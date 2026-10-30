# Origem das amostras de teste

Estas amostras são dependências de `tests/Test-RelatorioDell.ps1`. Não são necessárias para executar o relatório em um servidor e não são relatórios de uma consulta atual.

## Inventario-R530.txt

Baseado no texto de uma execução real de `DSU.exe --inventory`, versão 1.9.2.0, em um PowerEdge R530, fornecido pelo operador em 28/10/2026. O preâmbulo foi resumido; os 25 registros, seus nomes, tipos e versões foram preservados. O arquivo termina com `Exiting DSU!`.

O nome da máquina foi removido do nome do arquivo, e os testes usam `SRV-EXEMPLO`/`TESTE` como hostname/Service Tag fictícios. O texto do fixture não contém a Service Tag real. Os dados de hardware e versões mantêm o caso de regressão que revelou as pendências de BIOS e PERC e as limitações dos registros genéricos.

## dell-r530-resumo.json

Recorte de seis registros retornados pela interface interna de downloads do site oficial Dell, consultada em 28/10/2026 com `productcode=poweredge-r530` e `oscode=W12R2`. A resposta integral tinha 352 registros.

Foram mantidos campos necessários aos testes: identidade/título/tipo do pacote, criticidade textual, data, versão, categoria, nomes/tipos de arquivos e códigos de SO. Campos e descrições não usados foram removidos; `AppOses` teve duplicatas removidas. Portanto, o fixture é uma **amostra reduzida de dados reais**, não uma cópia integral da resposta e não uma previsão de todos os downloads atuais.

| DriverId | Uso na regressão | Referência Dell |
| --- | --- | --- |
| PVDNH | BIOS 2.19.0 | [Página do pacote](https://www.dell.com/support/home/en-us/drivers/driversdetails?driverid=pvdnh) |
| VWF72 | iDRAC 2.86.86.86 | [Página do pacote](https://www.dell.com/support/home/en-us/drivers/driversdetails?driverid=vwf72) |
| 89DRR | Referência antiga de iDRAC, para conferir escolha pela data | [Página do pacote](https://www.dell.com/support/home/en-us/drivers/driversdetails?driverid=89drr) |
| 700GG | Firmware PERC 25.5.9.0001 | [Página do pacote](https://www.dell.com/support/home/en-us/drivers/driversdetails?driverid=700gg) |
| DFF48 | Firmware Broadcom, preservado como inconclusivo sem identificação suficiente | [Página do pacote](https://www.dell.com/support/home/en-us/drivers/driversdetails?driverid=dff48) |
| CN7MV | Driver Broadcom; versão zero no inventário não é comparada | [Página do pacote](https://www.dell.com/support/home/en-us/drivers/driversdetails?driverid=cn7mv) |

A proveniência da consulta, URLs e hashes dos JavaScripts examinados estão em [docs/evidencias/api-dell-2026-10-28.json](../../docs/evidencias/api-dell-2026-10-28.json). As condições e os limites da API estão documentados no [README principal](../../README.md).

Alterações na resposta online não devem mudar silenciosamente estes fixtures. Para atualizá-los, registre uma nova coleta, preserve a origem e confira se as expectativas dos testes continuam corretas.

## Inventario-R530.xml e dell-r530-discos.json

Adicionados em 29/10/2026. O XML deriva do inventário real fornecido pelo operador, com `schemaVersion=1.0` e Inventory Collector `26.09.000 (BLD_22)`. Preserva as 25 aplicações, nomes, versões, modelos, ComponentIDs, FQDDs e PCI IDs; não contém Service Tag, hostname, serial de disco ou endereço de rede. O timestamp foi substituído por meia-noite. Foi convertido de UTF-16 para UTF-8; o teste reconstrói UTF-16 com BOM para verificar a leitura original. Não permite deduzir a versão do executável DSU usado na coleta.

O JSON contém somente os dois pacotes RG9MK e P183W, extraídos dos downloads normalizados da captura R530/Windows Server 2016 (`WST14`, 323 registros) de 29/10/2026. Preserva identidade, título, versão, criticidade, data, categoria e arquivos. Não altera o fixture anterior de seis registros (`W12R2`). As páginas oficiais conferidas são [Toshiba RG9MK / EG03](https://www.dell.com/support/home/en-us/drivers/driversdetails?driverid=rg9mk) e [Seagate P183W / LA0C](https://www.dell.com/support/home/en-us/drivers/driversdetails?driverid=p183w).

O coletor registra o Seagate como `ST8000NM023B-2TJ`, abreviação do modelo completo `ST8000NM023B-2TJ133` na página Dell. O código aceita apenas esses dois textos exatos, junto com ComponentID `111175` e FQDD de disco. Para Toshiba, exige `MG04SCA20ENY`, ComponentID `105266` e FQDD de disco. Esses IDs foram observados no XML; não são um contrato de associação publicado pela API.

Na primeira implementação, a regressão XML com os seis registros anteriores mais os dois discos mantinha 19 itens em escopo, cinco pendências, dois atualizados na referência e 12 inconclusivos. O resultado posterior com regras Broadcom está descrito abaixo. Os pares EG02/EG03 e LA0B/LA0C são regras locais explícitas, sem ordenação alfabética. Isso testa a associação implementada, sem executar DUPs ou certificar aplicabilidade. Os originais XML/HAR e relatórios do cliente não são versionados.

## dell-r530-broadcom-driver.json e regressões Broadcom

O novo JSON contém somente o pacote 49X84 do mesmo HAR R530/WST14 com 323 downloads, preservando os metadados normalizados. A versão de família é `21.80.3`, distinta do driver NDIS `214.0.0.6` nas [notas oficiais](https://downloads.dell.com/FOLDER07078680M/1/Release_user_NX1_v218.0.169.2.txt). Os pacotes DFF48/49X84 foram extraídos estaticamente; identidades PCI, hashes e limites estão em [evidência Broadcom](../../docs/evidencias/broadcom-2026-10-29.json). Não são distribuídos binários ou scripts de terceiros extraídos do DUP.

As tuplas `14E4:165F:14E4:2003` e `14E4:165F:1028:0639` estão nos dois `package.xml`. A coluna de família de `bcmnxfw.cfg` associa ambas à FFV `22.00.6`. Assim, a regressão XML passa a produzir 11 pendências, dois atualizados na referência e seis inconclusivos. A ressalva de suporte ao Windows 2016 do DFF48 permanece no motivo; comparação de versão não valida execução do instalador.

As seis linhas CIM são construídas **em memória com versões e identidades fictícias**; não são uma coleta real do servidor. A versão `214.0.0.5` é um exemplo sintético para exercitar pendência; a versão alvo `214.0.0.6` vem das notas oficiais. Assinatura/provedor dos fixtures são simulados. Com esse cenário, o driver de família deixa de ser inconclusivo; sem evidência CIM, continua inconclusivo. Nenhum teste consulta Windows Update ou driver real da máquina que executa a suíte.

## drivers-windows-net-exemplo.json e engine genérica

Baseado no `drivers-windows.json` real fornecido em 29/10/2026. Preserva seis dispositivos, proporção de perfis PCI (quatro `0639/1028`, dois `2003/14E4`), versão `17.2.1.0`, provedor Microsoft, `netb57va.inf` e indicação de assinatura. Os nomes foram substituídos e as partes de instância dos IDs PNP foram trocadas por `EXEMPLO1` a `EXEMPLO6`. Nenhuma identidade física, MAC, hostname ou Service Tag do cliente foi mantida.

A engine aceita esse provedor por hardware, assinatura indicada pelo CIM e referência Dell, sem comparar o nome Microsoft com uma lista de provedores permitidos. A regressão com os dados reais anonimizados produz 12 pendências, dois atualizados na referência e cinco inconclusivos. As 33 tuplas da base inicial vêm da interseção do package.xml com as famílias suportadas pelo coletor do 49X84; a [evidência da generalização](../../docs/evidencias/drivers-genericos-2026-10-29.json) registra as fontes.

Os testes com outros nomes de PowerEdge, outro fabricante/pacote, versões diferentes, números variáveis de interfaces e identidades divergentes são **sintéticos**. Demonstram que a lógica não usa R530, hostname, tag, versão 17.2.1.0, INF específico ou provedor como condição. Não comprovam suporte físico a todos esses servidores ou pacotes. A base de produção ainda contém somente o driver 49X84; outros pacotes exigem dados revisados, não novas condições por modelo na engine.

## pacote-auto/package.xml e pacote-auto/rede.inf

São arquivos **inteiramente sintéticos**, sem pacote executável ou assinatura real. O manifesto imita `SoftwareComponent` schema 1.0; o INF demonstra `DriverVer`, `Manufacturer`, modelos PCI e decorações amd64/build. IDs `A1B2C`, `9000` e `8086:1234:1028:ABCD` são dados de teste, não uma afirmação de produto suportado pela Dell.

O teste positivo extrai definições desses arquivos e compara com CIM sintético de versão inferior, sem uma referência fixa do pacote na engine. Outros casos recusam DTD, identidades divergentes, INFs ausentes, revisões/overrides não resolvidos e versões inválidas. Nos testes de cache, funções de rede, assinatura e extração são substituídas; não se inicia um DUP, instalador, Windows Update ou processo de fornecedor.

As evidências de leitura dos DUPs reais são separadas em [pacotes-automaticos-2026-10-29.json](../../docs/evidencias/pacotes-automaticos-2026-10-29.json). Binários e extrações reais não integram o repositório.

## Casos por Service Tag

Os campos `IsTag`, `ServiceTag`, `IsNoDriversFoundForTag` e `IsTagDriver` usados nos novos testes são **sintéticos**, acrescentados em memória pelo harness. A tag `ABC1234` e o identificador `0-TOKEN_SINTETICO_1234567890` são exemplos fictícios. Não representam uma consulta real por tag nem uma contagem validada online.

A seleção `IsTagDriver > 0` e o uso de `encryptedServiceTag` foram observados no JavaScript oficial da Dell. A tentativa de acesso online à página de uma tag real recebeu HTTP 403 neste ambiente; a evidência está em [docs/evidencias/api-dell-service-tag-2026-10-28.json](../../docs/evidencias/api-dell-service-tag-2026-10-28.json). Nenhuma tag real ou seu identificador foi incorporado aos arquivos de teste.

## Capturas HAR da importação manual

Os testes constroem capturas HAR **sintéticas** durante a execução, usando os seis downloads do JSON reduzido e os mesmos identificadores fictícios. As capturas, seus timestamps e os headers/cookies de teste não representam uma navegação real. São gravadas somente no diretório temporário exclusivo da suíte e removidas ao final. Não há um HAR de cliente incorporado ao repositório.

São exercitados corpos abertos, transformação Dell e codificação base64; contexto de modelo/SO; origem e método HTTP; respostas vazias ou com erro; capturas duplicadas/conflitantes; identidade clara de tag; metadados de proveniência e descarte de dados privados. Um caso cria arquivo acima de 100 MiB para testar a rejeição pelo tamanho antes da leitura. Outro inclui dados irrelevantes acima de 2 MiB para verificar a leitura no Windows PowerShell 5.1.

Sentinelas artificiais de cookies, autorização e campos privados permitem confirmar que o importador não copia o HAR integral para os diagnósticos. O cenário de regressão conserva as duas pendências e os 16 componentes inconclusivos da referência original. Os testes não demonstram que uma exportação real do navegador tenha sido recebida ou que a consulta automática por Service Tag funcione online.
