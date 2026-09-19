<?php
namespace ConfigManager\Exceptions;

class ServiceException extends \Exception
{
    private $errorCode;

    public function __construct(string $message, int $code = 0, ?\Throwable $previous = null)
    {
        $this->errorCode = $code;
        parent::__construct($message, $code, $previous);
    }

    public function getErrorCode()
    {
        return $this->errorCode;
    }

}