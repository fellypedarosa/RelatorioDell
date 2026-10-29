# Consulta de atualizações pela Service Tag: pesquisa e avaliação

Pesquisa realizada em **28/10/2026**, considerando PowerEdge com Windows Server, execução independente por cliente e relatório sem instalação de atualizações.

**Atualização da implementação:** a alternativa de importar um HAR está disponível por `-ArquivoSiteDell`, com testes offline e uma execução real validada em 29/10/2026 em R530/Windows Server 2016. A captura recebida usou escopo Modelo, não filtro por tag. O procedimento está em [Importação manual](Importacao-Manual-Dell.md) e os resultados estão no [README](../README.md#validação-real-da-importação-manual-em-29102026). As seções abaixo preservam a pesquisa original e suas propostas; não descrevem uma API automática por tag validada.

## Recomendação

O caminho a validar primeiro é **obter pelo navegador os dados da página Dell aberta pela Service Tag e comparar essa referência com o inventário atual do servidor**. A coleta pelo navegador pode começar assistida pelo analista e, depois de validada, receber automação. Isso permite investigar uma alternativa ao acesso direto que retornou HTTP 403, sem depender de uma nova API pública ainda não encontrada.

Esta é uma proposta técnica, **não uma integração já comprovada**. Nesta pesquisa não foi capturada uma resposta real por tag no navegador, não foi instalado um coletor e não foi alterada a engine do relatório. O bloqueio do fluxo HTTP atual permanece.

O motivo para investigar o navegador é concreto: o usuário já conseguiu abrir a página do servidor. Ainda é necessário comprovar o filtro usado, a identidade do equipamento e a integridade dos registros coletados.

## O que encontramos

| Caminho | Consulta pela tag? | Situação e avaliação |
| --- | --- | --- |
| Capturar a resposta já recebida pelo navegador | Sim, se a requisição e seus dados confirmarem a tag | Melhor primeira prova. Exige uma etapa assistida e importação no script, ainda não implementada. |
| Coletor de página ou automação do Edge | Pode operar a busca por tag e exportar os dados carregados | Candidato à evolução da primeira prova; acesso pela automação não foi testado. Acrescenta dependências e manutenção. |
| API pública/contratada TechDirect | Há APIs por tag para outras finalidades | Não foi encontrada documentação pública de endpoint que entregue a lista de firmware/drivers PowerEdge por tag. Requer confirmação específica da Dell. |
| Repository Manager 2.0 | Sim, documentado naquela versão | Evidência histórica útil. Funcionamento e suporte atuais não foram confirmados; não é recomendação de instalar uma versão antiga. |
| Repository Manager 3.5.0 e inventário iDRAC | O fluxo documentado usa inventário e catálogo | Alternativa de ferramentas oficiais para preparar repositórios, sem comprovar equivalência à lista do site por tag. |
| Redfish do iDRAC8 | Identifica recursos do próprio servidor | Fonte complementar de inventário; não substitui a consulta ao site por tag ou o inventário dos drivers do Windows. |

### 1. Usar os dados que o navegador já recebeu

O JavaScript oficial consultado distingue listas por produto e por tag, usa um identificador chamado `encryptedServiceTag` e seleciona os registros com `IsTagDriver > 0`. Também mantém as coleções `driverListTagData` e `driverListProductData`. Portanto, uma coleta pode investigar tanto a resposta recebida quanto os dados já processados pela página. Isso é inferência de implementação a partir do [JavaScript Dell](https://www.dellcdn.com/support/driver/bundle/dds2/js/v-1-3-617-613/driver-list.min.js), não um contrato de integração. A evidência local está em [api-dell-service-tag-2026-10-28.json](evidencias/api-dell-service-tag-2026-10-28.json).

A interface pode mostrar registros do modelo mesmo em uma página acessada pela tag. A captura precisa registrar qual lista foi usada; a presença da tag na URL não basta. A Dell também documenta a seleção de downloads específicos do equipamento na [FAQ de drivers](https://www.dell.com/support/kbdoc/en-bd/000123347/drivers-and-downloads-faqs).

A primeira prova pode ser feita sem construir uma automação:

1. No navegador em que o site funciona, abrir a página do servidor pela tag e selecionar o Windows efetivamente instalado.
2. Abrir as ferramentas de desenvolvedor, guia **Network/Rede**, e carregar normalmente a lista de downloads.
3. Localizar a resposta de downloads correspondente à busca por tag. Se só houver uma resposta por produto, registrar isso como consulta por modelo.
4. Usar **Copy response/Copiar resposta** na solicitação bem-sucedida e salvar somente seu corpo em arquivo local. A Microsoft documenta essa operação na [referência de rede do Edge](https://learn.microsoft.com/en-us/microsoft-edge/devtools/network/reference#copy-network-requests-to-the-clipboard).
5. Validar o arquivo antes de criar o importador: identidade, produto, SO, seleção por tag, quantidade, versões, criticidade e nomes dos pacotes.

Esse procedimento copia uma resposta já recebida. Não exige reproduzir cookies em PowerShell nem refazer a chamada bloqueada. O corpo pode conter identificadores do equipamento; deve permanecer nos arquivos operacionais do cliente, fora dos fixtures públicos. Um HAR completo não é necessário para essa prova.

**O que falta implementar:** importação dessa referência no script e validação da resposta real. O script atual ainda não tem um parâmetro para importar downloads salvos. Não basta salvar uma página HTML inicial: os dados podem ter sido carregados separadamente.

Depois da primeira prova, um coletor acionado na página pode ser mais simples para o analista que as ferramentas de desenvolvedor. Esse coletor precisará ser validado no contexto correto da página ou do iframe; não há nesta pesquisa um botão de exportação nativo da Dell confirmado.

### 2. Automatizar o navegador

A Microsoft documenta a automação do [Edge com WebDriver](https://learn.microsoft.com/en-us/microsoft-edge/webdriver-chromium/) e a [extração de tabelas pelo Power Automate para desktop](https://learn.microsoft.com/en-us/power-automate/desktop-flows/automation-web). Essas são tecnologias disponíveis, não comprovação de funcionamento com a página Dell.

Uma implementação poderia pesquisar a tag, selecionar SO/filtro, aguardar a lista e exportar os dados. Precisaria lidar com paginação, carregamento parcial e mudanças do site. Uma recusa de acesso continuaria sendo falha; a proposta não depende de ocultar a automação, trocar IP ou resolver desafios automaticamente.

Para manter os servidores simples, o coletor poderia rodar na estação do analista, enquanto inventário e comparação continuam no servidor. A referência seria transferida como arquivo. Isso dispensa acesso centralizado aos clientes, mas acrescenta um passo ao requisito original. Se a exigência for um único `.ps1` 5.1 sem interação nem dependências adicionais, esta alternativa não está demonstrada.

### 3. APIs TechDirect

A [página oficial de APIs TechDirect](https://www.dell.com/support/contents/en-us/article/product-support/self-support-knowledgebase/technologies-and-tools/techdirect/self-dispatch-and-apis) descreve garantia por Service Tag, solicitações de suporte e despacho de peças, com inscrição no serviço. Ela não documenta um endpoint de downloads de firmware PowerEdge por tag.

Não encontrar essa documentação não prova que uma API restrita a parceiros não exista. O próximo passo comercial seria pedir à Dell uma confirmação com este escopo exato, sem presumir que uma chave de garantia resolve o problema:

> Existe API suportada para um prestador consultar, por Service Tag e Windows Server, os downloads PowerEdge com versão, criticidade, data e pacote, incluindo servidores de 13ª geração? Quais são os requisitos de acesso, limites e custos?

Nenhum contato foi enviado e nenhum contrato, preço ou direito de uso dessa eventual API foi confirmado.

### 4. Repository Manager: distinguir a versão antiga da atual

O manual do **DRM 2.0** documenta **Schedule Automatic Search**, com busca por marca ou Service Tag, inclusive para sistemas legados. Isso demonstra que a própria Dell ofereceu esse fluxo naquela versão. Não comprova que o serviço usado por ela ainda esteja disponível. [Manual Dell 2.0](https://www.dell.com/support/manuals/en-us/dell-repstry-mngr-v2.0/drm_data_center_ug-v4/scheduling-automatic-search?guid=guid-4742323d-1c19-466e-8a80-ce154ef7bf65&lang=en-us).

O [manual atual 3.5.0](https://dl.dell.com/content/manual19321473-dell-repository-manager-version-3-5-0-user-s-guide.pdf?language=en-us), especialmente as seções de criação de repositórios, descreve catálogos e integração com inventário iDRAC/CMC. Não foi encontrada ali a confirmação de uma busca direta equivalente à antiga por tag. Essa ausência na documentação consultada não prova remoção absoluta de toda funcionalidade relacionada.

A Dell informa que o DRM não exige licença e que o catálogo DRM não inclui firmware de **CPLD e fontes de alimentação**. Portanto, ele não garante sozinho a cobertura desejada. [Página de suporte DRM](https://www.dell.com/support/kbdoc/en-us/000177083/support-for-dell-emc-repository-manager-drm).

### 5. Verificar os próprios pacotes, sem atualizar

Há uma segunda melhoria independente da forma de consultar a tag: para um **Dell Update Package Windows** que suporte a opção, a Dell documenta `/s /c` para verificar se a atualização é aplicável. Exemplo de sintaxe, **não executado nesta pesquisa**:

```powershell
.\PacoteDell.exe /s /c /l=C:\RelatoriosDell\verificacao-pacote.log
```

O `/c` precisa estar presente. Antes de usar, deve-se conferir a ajuda e a documentação do pacote. A proposta futura seria baixar apenas candidatos, verificar assinatura Dell e executar exclusivamente a verificação, guardando logs. Isso evita depender apenas de associação textual entre um nome genérico do inventário e um pacote. [Opções Windows de DUP](https://www.dell.com/support/manuals/pt-br/dell-update-packages/dup_framework_23.12.00_ug_pub/windows-cli-options?guid=guid-7e40f460-fdff-4cf9-b26f-e58065d8acbe&lang=en-us).

O resultado de aplicabilidade não deve ser convertido sozinho em “pendência confirmada”. Também é necessário interpretar versões, pré-requisitos, dispositivos atendidos e logs. O código 3, por exemplo, pode indicar versão igual ou tentativa de downgrade. [Códigos DUP](https://www.dell.com/support/manuals/en-gb/dell-update-packages/dup_framework_23.12.00_ug_pub/exit-codes-for-cli?guid=guid-709bb23f-1f40-492f-8774-bbed273df825&lang=en-us).

O custo operacional é baixar os candidatos e verificá-los; nem todo arquivo publicado é um DUP compatível com esse procedimento. Não foi testado um pacote real no servidor nesta pesquisa.

### 6. Inventário por Redfish

O iDRAC8 documenta a leitura de inventário de firmware via `GET /redfish/v1/UpdateService/FirmwareInventory`, com autenticação e privilégio de login. É uma alternativa a investigar para obter dados de hardware quando o texto do DSU for insuficiente. [Guia Redfish iDRAC8](https://www.dell.com/support/manuals/en-us/poweredge-t130/idrac8_redfishapiguide_2.70.70.70/softwareinventorycollection?guid=guid-6f9ae2f8-02d7-40c4-ae37-f2e5019c2938&lang=en-us).

Essa leitura não é uma consulta ao site Dell por Service Tag e, isoladamente, não fornece a lista de drivers Windows pendentes. Exigiria acesso e credenciais ao iDRAC de cada cliente; isso não foi validado no ambiente do usuário.

## Teste de aceitação antes de alterar o padrão

A primeira prova deve usar o R530 já conhecido e depois um servidor de outro modelo:

1. Capturar uma resposta real, distinguindo tag de modelo, e validar a identidade e o Windows instalado.
2. Conferir manualmente alguns registros no site: pacote, versão, criticidade e data.
3. Comprovar a completude da captura, incluindo paginação e todos os downloads apresentados para a seleção, sem confundir essa contagem com pendências.
4. Comparar com inventário concluído do mesmo servidor, preservando casos sem associação segura como inconclusivos.
5. Se usada a checagem de DUP, validar primeiro um pacote conhecido em modo de verificação, sem instalar.
6. Só depois classificar o fluxo como funcional e avaliar automatização ou mudança de padrão.

O critério é conseguir repetir uma coleta real correta. Passar testes com respostas simuladas ou abrir uma URL não satisfaz esse critério.

## Impacto no projeto

Esta entrega adiciona a avaliação e um link no README. Não altera a consulta, as regras de comparação ou as opções do script. A engine atual continua com cobertura parcial, e o fluxo automático por tag continua sem validação online de sucesso.
