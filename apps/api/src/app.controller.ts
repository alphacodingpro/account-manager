import { Controller, Get } from '@nestjs/common';

@Controller()
export class AppController {
  @Get('health')
  health() { return { status: 'ok', service: 'cloudledger-pk-api', timestamp: new Date().toISOString() }; }
}

