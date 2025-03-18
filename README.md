# CameraDiagnostic + VCamInjector

![Badge](https://img.shields.io/badge/iOS-14.0%2B-blue)
![Badge](https://img.shields.io/badge/Status-Beta-yellow)

## Visão Geral

Este projeto é uma solução híbrida para diagnóstico e substituição do feed da câmera do iOS. É dividido em dois componentes principais:

1. **CameraDiagnostic**: Ferramenta que monitora e registra detalhadamente o funcionamento da câmera em aplicativos iOS.
2. **VCamInjector**: Sistema de injeção que substitui o feed de vídeo da câmera em tempo real, mantendo metadados e compatibilidade.

## Objetivo

O objetivo deste projeto é possibilitar uma substituição transparente e indetectável do feed de câmera do iOS, utilizando dados detalhados coletados sobre o pipeline de processamento de imagem para garantir compatibilidade total com aplicativos. O principal caso de uso é substituir o feed da câmera com um stream de vídeo recebido via WebRTC, criando uma solução completa de câmera virtual para iOS.

## Arquitetura da Solução

### Componente de Diagnóstico (CameraDiagnostic)

Este componente realiza uma análise detalhada do pipeline de câmera, registrando:

- Configurações precisas de sessão de câmera
- Formatos de pixel e resolução em cada estágio
- Orientações e transformações de vídeo
- Metadados de foto e vídeo
- Pontos potenciais para injeção

Arquivos principais:
- `DiagnosticTweak.h/.xm`: Define o núcleo do sistema de diagnóstico
- `DiagnosticHooks.xm`: Ganchos para monitorar o pipeline da câmera
- `DiagnosticExtension.xm`: Análise avançada para identificar pontos de injeção
- `Utils/Logger.mm`: Sistema de logging avançado
- `Utils/MetadataExtractor.mm`: Extração detalhada de metadados da câmera

### Componente de Injeção (VCamInjector)

Este componente implementa a substituição híbrida, que:

1. Intercepta frames de vídeo no ponto ideal do pipeline
2. Substitui o conteúdo visual mantendo metadados e propriedades originais
3. Preserva as expectativas das aplicações quanto a formato, timing e propriedades

Arquivos principais:
- `VCamInjector.h/.mm`: Implementa o sistema de injeção e substituição de frames
- `VCamHook.xm`: Ganchos específicos para pontos de injeção identificados
- `VCamConfiguration`: Gerenciamento de configurações e persistência

## Como Funciona a Substituição Híbrida

A abordagem híbrida combina:

1. **Interceptação de frames**: Intercepta o fluxo de vídeo em `captureOutput:didOutputSampleBuffer:fromConnection:`, ponto onde cada frame é entregue ao aplicativo.

2. **Preservação de metadados**: Mantém todos os metadados originais (timestamps, formato, orientação) para uma substituição transparente.

3. **Adaptação dinâmica**: Ajusta-se automaticamente a diferentes resoluções, orientações e formatos conforme o diagnóstico em tempo real.

4. **Gerenciamento de sessão**: Monitora e adapta-se a mudanças na sessão de câmera para manter consistência.

## Pontos Críticos de Injeção

O diagnóstico identificou os seguintes pontos ideais para injeção:

1. **Nível de frame (implementado)**
   - Em `captureOutput:didOutputSampleBuffer:fromConnection:`
   - Vantagem: Acesso direto ao buffer antes do processamento pelo app

2. **Nível de renderização (monitorado)**
   - Em `AVCaptureVideoPreviewLayer` e `AVSampleBufferDisplayLayer` 
   - Utilizado para diagnóstico e confirmação de sucesso da injeção

## Arquivos da Solução

### Componente de Diagnóstico
- `DiagnosticTweak.h`: Definições e interfaces do sistema
- `DiagnosticTweak.xm`: Implementação principal
- `DiagnosticHooks.xm`: Hooks do sistema AVFoundation
- `DiagnosticExtension.xm`: Análise avançada e identificação de pontos de injeção
- `Utils/Logger.h/.mm`: Sistema de logging
- `Utils/MetadataExtractor.h/.mm`: Extração de metadados

### Componente de Injeção
- `VCamInjector.h`: Interface do sistema de injeção
- `VCamInjector.mm`: Implementação do sistema de injeção
- `VCamHook.xm`: Hooks principais para substituição

### Arquivos de Build
- `Makefile`: Compilação do projeto
- `Filter.plist`: Configuração de injeção
- `control`: Metadados do pacote

## Instalação e Uso

1. **Prepare o ambiente:**
   ```bash
   export THEOS=/opt/theos
   ```

2. **Compile o projeto:**
   ```bash
   make package
   ```

3. **Instale no dispositivo com jailbreak:**
   ```bash
   make install
   ```

4. **Configure o feed substituto:**
   - Coloque a imagem ou vídeo em `/var/mobile/Library/Application Support/VCamMJPEG/`
   - Edite a configuração em `/var/mobile/Library/Application Support/VCamMJPEG/config.plist`

### Teste com Diferentes Fontes de Feed

#### Imagem Estática (padrão)
```xml
<dict>
    <key>sourceType</key>
    <string>file</string>
    <key>sourcePath</key>
    <string>/var/mobile/Library/Application Support/VCamMJPEG/default.jpg</string>
    <key>preserveAspectRatio</key>
    <true/>
</dict>
```

#### Stream WebRTC (quando implementado)
```xml
<dict>
    <key>sourceType</key>
    <string>webrtc</string>
    <key>webRTCServerURL</key>
    <string>wss://your-signaling-server.com</string>
    <key>webRTCRoomID</key>
    <string>camera-feed-room</string>
    <key>preserveAspectRatio</key>
    <true/>
</dict>
```

### Verificando o Funcionamento

Para confirmar que o sistema está funcionando:

1. **Verificação visual:** Abra um aplicativo de câmera e confirme se o feed foi substituído
2. **Verificação de logs:** Examine `/var/tmp/CameraDiagnostic/diagnostic.log`
3. **Capture fotos/vídeos:** Tire fotos ou grave vídeos para confirmar que o conteúdo substituído é usado
4. **Teste em diferentes apps:** Verifique a compatibilidade em Camera.app, Instagram, WhatsApp, etc.

Se estiver usando WebRTC, o log mostrará informações de conexão e estatísticas de streaming.

## Diagnóstico e Logs

Os logs são armazenados em:
- `/var/tmp/CameraDiagnostic/diagnostic.log` - Log principal
- `/var/tmp/CameraDiagnostic/[app]_[bundle]_diagnostics.json` - Dados por aplicativo

## Implementação do Suporte a WebRTC

A arquitetura permite facilmente a integração de streams WebRTC como fonte de substituição para a câmera. Abaixo estão os passos para implementar esta funcionalidade:

### 1. Configuração do Componente WebRTC

1. **Adicionar a biblioteca WebRTC ao projeto**
   ```bash
   # Adicionar dependências no Makefile
   VCamInjector_LIBRARIES = WebRTC
   ```

2. **Criar uma classe gerenciadora de WebRTC**
   - Crie um arquivo `WebRTCManager.h/mm` para lidar com a conexão e recepção de frames
   - Implemente métodos para estabelecer conexão e receber frames de vídeo
   - Mantenha uma fila de frames mais recentes para evitar inconsistências temporais

### 2. Integração com o VCamInjector

3. **Adicionar novo tipo de fonte em VCamInjector.h**
   ```objective-c
   // Em VCamInjector.mm, adicionar constante
   static NSString * const kSourceTypeWebRTC = @"webrtc";
   ```

4. **Implementar método para obter frames WebRTC**
   ```objective-c
   // Adicionar em VCamInjector.mm
   - (CVPixelBufferRef)pixelBufferFromWebRTC {
       if (!_webRTCManager || !_webRTCManager.isConnected) {
           return NULL;
       }
       
       // Obter o frame mais recente da stream WebRTC
       RTCVideoFrame *rtcFrame = [_webRTCManager lastReceivedFrame];
       if (!rtcFrame) {
           return NULL;
       }
       
       // Converter frame WebRTC para CVPixelBuffer
       CVPixelBufferRef pixelBuffer = [self convertRTCFrameToPixelBuffer:rtcFrame];
       
       return pixelBuffer;
   }
   
   - (CVPixelBufferRef)convertRTCFrameToPixelBuffer:(RTCVideoFrame *)frame {
       // Implementação da conversão do formato WebRTC para CVPixelBuffer
       // Detalhes dependem da biblioteca WebRTC específica
       // Retorna um CVPixelBuffer compatível com o pipeline da câmera
   }
   ```

5. **Modificar processVideoSampleBuffer para usar a fonte WebRTC**
   ```objective-c
   // Em VCamInjector.mm, método processVideoSampleBuffer
   if ([self.sourceType isEqualToString:kSourceTypeWebRTC]) {
       // Usar WebRTC como fonte
       replacementBuffer = [self pixelBufferFromWebRTC];
   }
   ```

### 3. Implementação do Cliente WebRTC

6. **Componentes necessários na classe WebRTCManager**
   - Gerenciador de sinalização (Signaling)
   - Estabelecimento de conexão P2P 
   - Recepção e decodificação de frames de vídeo
   - Conversão para o formato necessário do iOS

7. **Lidando com conectividade**
   ```objective-c
   // Em WebRTCManager.mm
   - (void)connectToSignalingServer:(NSString *)serverURL roomID:(NSString *)roomID {
       // Conectar ao servidor de sinalização
       // Configurar candidatos ICE
       // Estabelecer conexão P2P
   }
   
   - (void)handleVideoTrack:(RTCVideoTrack *)videoTrack {
       // Configurar recepção de frames
       // Implementar delegate para receber frames
   }
   ```

8. **Configuração de adaptação de qualidade**
   - Implementar detecção de largura de banda
   - Ajustar resolução e framerate dinâmicamente
   - Sincronizar com as capacidades do dispositivo

### 4. Interface de Configuração

9. **Configurações específicas de WebRTC**
   ```objective-c
   // Em VCamConfiguration.h, adicionar propriedades
   @property (nonatomic, strong) NSString *webRTCServerURL;
   @property (nonatomic, strong) NSString *webRTCRoomID;
   @property (nonatomic, assign) BOOL webRTCAutomaticQuality;
   @property (nonatomic, assign) CGSize webRTCPreferredResolution;
   ```

10. **Salvar e carregar as configurações**
    ```objective-c
    // Em VCamConfiguration.mm, método currentSettings
    @{
        ...
        @"webRTCServerURL": self.webRTCServerURL ?: @"",
        @"webRTCRoomID": self.webRTCRoomID ?: @"",
        @"webRTCAutomaticQuality": @(self.webRTCAutomaticQuality),
        @"webRTCPreferredWidth": @(self.webRTCPreferredResolution.width),
        @"webRTCPreferredHeight": @(self.webRTCPreferredResolution.height)
    }
    ```

### 5. Considerações Especiais para WebRTC

- **Latência**: Otimizar para minimizar atraso entre recepção e exibição
- **Recuperação de perda de pacotes**: Implementar métodos para lidar com frames perdidos
- **Sincronização de tempo**: Garantir que o timestamping dos frames WebRTC seja compatível
- **Adaptação de formato**: Converter entre formatos de cor e compressão usados por WebRTC e AVFoundation
- **Uso de recursos**: Monitorar uso de CPU e memória para evitar impacto no desempenho

### 6. Exemplo de Configuração WebRTC

Uma configuração típica no arquivo config.plist seria:

```xml
<dict>
    <key>sourceType</key>
    <string>webrtc</string>
    <key>webRTCServerURL</key>
    <string>wss://your-signaling-server.com</string>
    <key>webRTCRoomID</key>
    <string>camera-feed-room</string>
    <key>webRTCAutomaticQuality</key>
    <true/>
    <key>preserveAspectRatio</key>
    <true/>
    <key>mirrorOutput</key>
    <true/>
</dict>
```

## Próximos Passos

1. **Implementação de WebRTC**
   - Integração completa do cliente WebRTC
   - Otimização de desempenho para streaming em tempo real
   - Gerenciamento de conexão e reconexão automática

2. **Melhoria de desempenho**
   - Otimização de processamento de buffer para reduzir latência
   - Implementação de cache inteligente para formatos comuns

3. **Filtros em tempo real**
   - Implementação de efeitos de câmera personalizados
   - Pipeline de processamento de imagem extensível

## Requisitos

- iOS 14.0 ou superior
- Dispositivo com jailbreak
- Theos para compilação

## Licença

Este projeto é fornecido para uso educacional e pessoal apenas.